#!/usr/bin/env python3
"""Prometheus exporter for u-blox UBX-MON-RF, for the Pi 5 stratum 1 server.

gpsd owns /dev/ttyAMA0 exclusively and runs read-only (``-b``), so nothing on
the system can poll the module.  The module is instead configured to *emit*
UBX-MON-RF on UART1 every few navigation epochs; this exporter subscribes to
gpsd's raw byte stream and decodes those frames as they go past on their way
to the NMEA parser.  It never writes to gpsd or to the module.

Serves on :9016.  See README.md for the module-side configuration and for the
value mappings the Grafana panels use.
"""

from __future__ import annotations

import logging
import socket
import struct
import sys
import time
from typing import Iterator, NamedTuple

from prometheus_client import Counter, Gauge, start_http_server

GPSD_HOST = "127.0.0.1"
GPSD_PORT = 2947
EXPORTER_PORT = 9016

# raw:2 asks gpsd for the undecoded device bytes, the same thing `gpspipe -R`
# requests.  gpsd still prefixes the session with its JSON banner, which the
# frame scanner skips over as non-UBX noise.
WATCH_COMMAND = b'?WATCH={"enable":true,"raw":2};\n'

RECONNECT_DELAY_S = 5.0
SOCKET_TIMEOUT_S = 30.0
READ_SIZE = 4096
# One MON-RF block is 28 bytes; a healthy stream never needs a big buffer.
# The cap only bounds memory if the sync bytes never appear.
MAX_BUFFER_BYTES = 65536
# A stray sync pair inside NMEA text yields a garbage length field. Without a
# ceiling the scanner would stall waiting for a frame of that claimed size, so
# anything larger than the biggest message u-blox actually sends is rejected
# on sight rather than waited for.
MAX_PAYLOAD_BYTES = 2048

UBX_SYNC = b"\xb5\x62"
UBX_HEADER_LEN = 6
UBX_CHECKSUM_LEN = 2
MON_RF_CLASS_ID = (0x0A, 0x38)

MON_RF_HEADER = struct.Struct("<BBBB")
MON_RF_BLOCK = struct.Struct("<BBBBLBBBBHHBbBbBBBB")

# u-blox reports AGC as a count over this full-scale range, not a percentage.
AGC_FULL_SCALE = 8191.0

LABELS = ("block",)

up = Gauge("gnss_rf_up", "1 when the gpsd raw stream is connected and readable")
frames = Counter("gnss_rf_frames_total", "UBX-MON-RF frames decoded")
bad_checksums = Counter(
    "gnss_rf_checksum_errors_total", "UBX frames dropped on checksum mismatch"
)
last_frame = Gauge(
    "gnss_rf_last_frame_timestamp_seconds",
    "Unix time of the most recent UBX-MON-RF frame",
)

jamming_state = Gauge(
    "gnss_rf_jamming_state",
    "0=unknown/disabled 1=ok 2=warning 3=critical",
    LABELS,
)
jamming_indicator = Gauge(
    "gnss_rf_jamming_indicator",
    "CW jamming indicator, 0=no CW interference to 255=strong",
    LABELS,
)
noise_per_ms = Gauge("gnss_rf_noise_per_ms", "Measured noise level", LABELS)
agc_count = Gauge("gnss_rf_agc_count", f"AGC monitor, 0..{int(AGC_FULL_SCALE)}", LABELS)
agc_ratio = Gauge(
    "gnss_rf_agc_ratio", "AGC monitor as a fraction of full scale", LABELS
)
antenna_status = Gauge(
    "gnss_rf_antenna_status",
    "0=init 1=unknown 2=ok 3=short 4=open",
    LABELS,
)
antenna_power = Gauge(
    "gnss_rf_antenna_power", "0=off 1=on 2=unknown", LABELS
)
post_status = Gauge(
    "gnss_rf_post_status", "Power-on self-test word, nonzero means a fault", LABELS
)
iq_offset_i = Gauge("gnss_rf_iq_offset_i", "Imbalance: I-component offset", LABELS)
iq_offset_q = Gauge("gnss_rf_iq_offset_q", "Imbalance: Q-component offset", LABELS)
iq_magnitude_i = Gauge(
    "gnss_rf_iq_magnitude_i", "Imbalance: I-component magnitude", LABELS
)
iq_magnitude_q = Gauge(
    "gnss_rf_iq_magnitude_q", "Imbalance: Q-component magnitude", LABELS
)


class RfBlock(NamedTuple):
    """One per-band RF block from a UBX-MON-RF payload."""

    block_id: int
    jamming_state: int
    antenna_status: int
    antenna_power: int
    post_status: int
    noise_per_ms: int
    agc_count: int
    jamming_indicator: int
    offset_i: int
    magnitude_i: int
    offset_q: int
    magnitude_q: int


def ubx_checksum(data: bytes) -> tuple[int, int]:
    """Return the 8-bit Fletcher checksum pair over class, id, length, payload."""
    ck_a = 0
    ck_b = 0
    for byte in data:
        ck_a = (ck_a + byte) & 0xFF
        ck_b = (ck_b + ck_a) & 0xFF
    return ck_a, ck_b


def parse_mon_rf(payload: bytes) -> list[RfBlock]:
    """Decode a UBX-MON-RF payload into its per-band blocks."""
    _version, n_blocks, _res_a, _res_b = MON_RF_HEADER.unpack_from(payload, 0)
    blocks: list[RfBlock] = []
    for index in range(n_blocks):
        offset = MON_RF_HEADER.size + (MON_RF_BLOCK.size * index)
        if offset + MON_RF_BLOCK.size > len(payload):
            logging.warning("MON-RF truncated at block %d, ignoring rest", index)
            break
        fields = MON_RF_BLOCK.unpack_from(payload, offset)
        blocks.append(
            RfBlock(
                block_id=fields[0],
                jamming_state=fields[1] & 0x03,
                antenna_status=fields[2],
                antenna_power=fields[3],
                post_status=fields[4],
                noise_per_ms=fields[9],
                agc_count=fields[10],
                jamming_indicator=fields[11],
                offset_i=fields[12],
                magnitude_i=fields[13],
                offset_q=fields[14],
                magnitude_q=fields[15],
            )
        )
    return blocks


def publish(block: RfBlock) -> None:
    """Update every gauge for one RF block."""
    label = str(block.block_id)
    jamming_state.labels(label).set(block.jamming_state)
    jamming_indicator.labels(label).set(block.jamming_indicator)
    noise_per_ms.labels(label).set(block.noise_per_ms)
    agc_count.labels(label).set(block.agc_count)
    agc_ratio.labels(label).set(block.agc_count / AGC_FULL_SCALE)
    antenna_status.labels(label).set(block.antenna_status)
    antenna_power.labels(label).set(block.antenna_power)
    post_status.labels(label).set(block.post_status)
    iq_offset_i.labels(label).set(block.offset_i)
    iq_offset_q.labels(label).set(block.offset_q)
    iq_magnitude_i.labels(label).set(block.magnitude_i)
    iq_magnitude_q.labels(label).set(block.magnitude_q)


def iter_ubx_frames(stream: Iterator[bytes]) -> Iterator[tuple[int, int, bytes]]:
    """Yield (class, id, payload) for each checksum-valid UBX frame in `stream`.

    Anything that is not a UBX frame — gpsd's JSON banner, the NMEA sentences
    sharing the same UART — is skipped by resynchronising on the next sync pair.
    """
    buffer = bytearray()
    for chunk in stream:
        buffer.extend(chunk)
        if len(buffer) > MAX_BUFFER_BYTES:
            del buffer[:-MAX_BUFFER_BYTES]
        while True:
            start = buffer.find(UBX_SYNC)
            if start < 0:
                # Keep one byte: the stream may have split a sync pair.
                del buffer[: max(0, len(buffer) - 1)]
                break
            del buffer[:start]
            if len(buffer) < UBX_HEADER_LEN:
                break
            msg_class, msg_id, length = struct.unpack_from("<BBH", buffer, 2)
            if length > MAX_PAYLOAD_BYTES:
                del buffer[:2]
                continue
            total = UBX_HEADER_LEN + length + UBX_CHECKSUM_LEN
            if len(buffer) < total:
                break
            body = bytes(buffer[2 : UBX_HEADER_LEN + length])
            expected = (buffer[total - 2], buffer[total - 1])
            if ubx_checksum(body) == expected:
                yield msg_class, msg_id, body[4:]
                del buffer[:total]
            else:
                # A bad checksum usually means the sync pair was really payload
                # bytes, so step past it rather than past the whole claimed frame.
                bad_checksums.inc()
                del buffer[:2]


def read_gpsd() -> Iterator[bytes]:
    """Yield raw byte chunks from gpsd, reconnecting for as long as it takes."""
    while True:
        try:
            with socket.create_connection(
                (GPSD_HOST, GPSD_PORT), timeout=SOCKET_TIMEOUT_S
            ) as conn:
                conn.sendall(WATCH_COMMAND)
                up.set(1)
                logging.info("connected to gpsd at %s:%d", GPSD_HOST, GPSD_PORT)
                while True:
                    chunk = conn.recv(READ_SIZE)
                    if not chunk:
                        raise ConnectionError("gpsd closed the connection")
                    yield chunk
        except OSError as error:
            up.set(0)
            logging.warning("gpsd stream lost (%s), retrying", error)
            time.sleep(RECONNECT_DELAY_S)


def main() -> int:
    """Serve MON-RF metrics until killed."""
    logging.basicConfig(
        format="%(levelname)s %(message)s", level=logging.INFO, stream=sys.stderr
    )
    start_http_server(EXPORTER_PORT)
    up.set(0)
    for msg_class, msg_id, payload in iter_ubx_frames(read_gpsd()):
        if (msg_class, msg_id) != MON_RF_CLASS_ID:
            continue
        for block in parse_mon_rf(payload):
            publish(block)
        frames.inc()
        last_frame.set(time.time())
    return 0


if __name__ == "__main__":
    sys.exit(main())
