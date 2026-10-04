# Monitoring — chrony + gpsd → Prometheus → Grafana

Prometheus exporters, scrape config, recording rule and Grafana alerts for the
stratum 1 server built in the [main README](../README.md). `time.example.com`
stands in for the Pi's hostname throughout; substitute your own.

Four exporters run natively on the Pi. No containers: chrony_exporter needs the
`chronyd` control socket, gpsd_exporter and gnss_rf_exporter need loopback gpsd,
and node_exporter needs real `/proc`, `/sys` and hwmon — all of which mean host
networking and bind mounts anyway. Docker would add two daemons of scheduler
noise to a machine whose whole job is not having any.

## Files

| File | Goes to |
|---|---|
| `chrony_exporter.service` | `/etc/systemd/system/` on the Pi |
| `gpsd_exporter.service` | `/etc/systemd/system/` on the Pi |
| `gnss_rf_exporter.py` | `/usr/local/bin/` on the Pi |
| `gnss_rf_exporter.service` | `/etc/systemd/system/` on the Pi |
| `grafana-alerts.yml` | `/etc/grafana/provisioning/alerting/ntp.yml` on the Grafana host — **renamed** |
| `prometheus-scrape.yml` | merge into `scrape_configs` on the Prometheus host |
| `prometheus-rules.yml` | `/etc/prometheus/rules/chrony.yml` on the Prometheus host |

Commands under **Install** run on the Pi, from a clone of this repo's
`monitoring/` directory.

## Install

### chrony_exporter — port 9123

Releases are plain tarballs — no `.deb`, and no unit file in the archive, so
`chrony_exporter.service` from this directory is the only unit involved.

```bash
VER=0.14.0
# --fail matters: without it a mistyped URL saves GitHub's 404 page under the
# tarball name and tar reports a bogus "not in gzip format".
curl -sSLO --fail "https://github.com/SuperQ/chrony_exporter/releases/download/v${VER}/chrony_exporter-${VER}.linux-arm64.tar.gz"
tar xzf chrony_exporter-${VER}.linux-arm64.tar.gz
sudo install -m 755 chrony_exporter-${VER}.linux-arm64/chrony_exporter /usr/local/bin/
```

No service account needs creating — the unit runs as `_chrony`, which the chrony
package already owns.

Before enabling, confirm the socket owner — the account is `_chrony` on
Debian/Ubuntu but `chrony` elsewhere, and the unit's `User=` must match:

```bash
stat -c '%U:%G %a' /run/chrony/chronyd.sock
```

Then run it in the foreground once. Pass the collector flags — only
`collector.tracking` defaults to on, so without them you get 15 metrics and no
sources regardless of whether anything is actually wrong:

```bash
sudo -u _chrony /usr/local/bin/chrony_exporter \
    --chrony.address=unix:///run/chrony/chronyd.sock \
    --collector.sources --collector.sourcestats \
    --collector.sources.with-ntpdata --collector.serverstats

curl -s localhost:9123/metrics | grep '^chrony_' | sed 's/[ {].*//' | sort | uniq -c
```

Expect `chrony_sources_*` samples for all four sources — the two NTP servers
plus the `NMEA` and `kPPS` refclocks. If tracking metrics appear but
`chrony_serverstats_*` does not, the socket connected while the query ran
unprivileged: recheck `User=` against the socket owner.

`chrony_sources_peer_*` covers only 2 of the 4. Those come from the `ntpdata`
collector, which reports wire-protocol detail and so skips refclocks. Build
refclock panels on `chrony_sources_last_sample_*`, not `peer_*`, or the `NMEA`
and `kPPS` series come back empty.

### gpsd_exporter — port 9015

Install the Python gps bindings from apt, **not** pip. `python3-gps` is
version-locked to the packaged gpsd (3.25); the PyPI `gps` package is a
different, incompatible library and will fail to parse the JSON stream.

```bash
sudo apt install python3-prometheus-client python3-gps
git clone https://github.com/brendanbank/gpsd-prometheus-exporter.git
sudo install -m 755 gpsd-prometheus-exporter/gpsd_exporter.py /usr/local/bin/
```

Use `gpsd_exporter.service` from this directory rather than the one in the repo.

No change to `/etc/default/gpsd` is required — the exporter is a normal gpsd
client on `127.0.0.1:2947`, and `-n` means gpsd is already polling.

### node_exporter — port 9100

```bash
sudo apt install prometheus-node-exporter
```

That is the whole install — the package ships its own unit, service account and
`/etc/default/prometheus-node-exporter`, and starts on `:9100` by default. No
unit file from this directory is involved. Note the service is named
`prometheus-node-exporter`, not `node_exporter`.

Confirm it is up and find the temperature metric, which differs by platform:

```bash
systemctl status prometheus-node-exporter
curl -s localhost:9100/metrics | grep -E '^node_(hwmon|thermal_zone)_temp'
```

Use whichever of the two the Pi 5 actually emits in the tempcomp panel below.

### gnss_rf_exporter — port 9016

Interference and antenna-fault metrics decoded from UBX-MON-RF. `CFG-ITFM-ENABLE`
has been on since March 2026 but nothing has ever read the result, so a degraded
antenna or a new CW source nearby would show up only as unexplained PPS jitter.

**Why this is not just `ubxtool -p MON-RF` on a timer.** gpsd holds `/dev/ttyAMA0`
open exclusively, so a second reader cannot have the port, and gpsd runs `-b`
(read-only) precisely so it never writes to the module — which also means a poll
sent *through* gpsd goes nowhere. Dropping `-b` is not an option; it is what stops
gpsd from probing over the BBR config. So the module is told to emit MON-RF on its
own, and the exporter reads it out of the stream gpsd is already receiving.

Confirmed present on this module: the integration manual (UBX-20053088) names
UBX-MON-RF as the source of antenna supervisor status and of the `antStatus` /
`antPower` fields, and ubxtool 3.25 carries both the
`CFG-MSGOUT-UBX_MON_RF_UART1` key (`0x2091035a`) and a MON-RF decoder.

**The antenna fields are live on this board.** The Uputronics datasheet lists
only a 2.7 V antenna bias and no supervisor circuitry, which suggested `antStatus`
would sit at `0` (init) or `1` (unknown) forever — but it reports `2` (OK) with
`antPower` `1` (on). Untested against a real fault, though: an OK reading proves
the field is populated, not that a short or open would actually be detected.
Treat an `antStatus` alert as a bonus rather than as verified antenna monitoring
until the antenna has been unplugged once to confirm the transition.

#### 1. Enable the message on the module

One `CFG-MSGOUT` key, rate in navigation epochs — nav rate is 1 Hz, so 5 means
every 5 s. That is 36 bytes on the wire per emission; at 115200 baud, nothing.

**Test in RAM first.** Layer 1 is deliberate here: this is the one class of change
that has broken NMEA output before (see the `CFG-MSGOUT-NMEA_ID_*` warning in
`configure_m10s.sh`), and RAM-only means a power cycle undoes it.

```bash
sudo systemctl stop gpsd
sudo ubxtool -z CFG-MSGOUT-UBX_MON_RF_UART1,5,1 -f /dev/ttyAMA0 -s 115200 -P 34.10
sudo systemctl start gpsd
```

Verify NMEA still flows and chrony is undisturbed before going further:

```bash
cgps                                  # fix and satellites still there?
chronyc sources -v                    # kPPS still '#*', NMEA still reaching 377
gpspipe -R | timeout 10 od -An -tx1 | grep -c 'b5 62'   # UBX frames present
```

Only once all three look right, make it persistent and add it to the boot script:

```bash
sudo systemctl stop gpsd
sudo ubxtool -z CFG-MSGOUT-UBX_MON_RF_UART1,5,3 -f /dev/ttyAMA0 -s 115200 -P 34.10
sudo systemctl start gpsd
```

Layer 3 is RAM+BBR, same as every other setting in `configure_m10s.sh`, and for
the same reason — BBR alone only survives while the supercap holds, so the value
belongs in the boot script too or it is gone after a long power-off. Add it as a
step in `../scripts/configure_m10s.sh` and re-copy to `/usr/local/sbin/`:

```bash
# Emit UBX-MON-RF on UART1 every 5 navigation epochs (5 s at the 1 Hz nav rate)
# so the RF/interference exporter has something to read. gpsd runs read-only,
# so the module has to push this; nothing on the Pi can poll for it.
ubxtool -z CFG-MSGOUT-UBX_MON_RF_UART1,5,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
RESPONSE=$(ubxtool -g CFG-MSGOUT-UBX_MON_RF_UART1 -f "$DEV" -s "$BAUD" -P "$PROTVER" 2>&1 || true)
if echo "$RESPONSE" | grep -q "val 5"; then
    echo "  MON-RF output enabled at 5 s"
else
    echo "  WARNING: Could not verify MON-RF output setting"
fi
```

The script is left unedited here on purpose — its copy runs on every boot, and a
`CFG-MSGOUT` key that has not been through the RAM test above does not belong in
the guaranteed recovery path.

**Rollback** is the same command with rate 0, or just a power cycle while it is
still layer 1.

#### 2. Install the exporter

```bash
sudo apt install python3-prometheus-client   # already present for gpsd_exporter
sudo install -m 755 gnss_rf_exporter.py /usr/local/bin/
sudo install -m 644 gnss_rf_exporter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gnss_rf_exporter
```

Check it is decoding rather than merely running — `gnss_rf_up` only reports the
gpsd connection, so the counter is the real signal:

```bash
curl -s localhost:9016/metrics | grep -E '^gnss_rf_(up|frames_total|jamming|antenna)'
```

`gnss_rf_frames_total` climbing means step 1 took. If it stays at 0 while
`gnss_rf_up` is 1, the module is not emitting and the problem is the `CFG-MSGOUT`
key, not the exporter.

systemd logs `Special user nobody configured, this is not safe!` at start. Same
`User=nobody` as `gpsd_exporter.service`, same warning there, and the exporter
needs no identity of its own — it only opens a loopback socket and an HTTP port.

**gpsd relabels the device `u-blox` once UBX frames appear**, where it read
`NMEA0183` before. This is cosmetic *because* of `-b`: gpsd picks the u-blox
driver but, being read-only, never sends the configuration probes that driver
would otherwise push at the module. NMEA parsing is unaffected — the `NMEA`
refclock stays at reach 377 and TPV still reports a 3D fix. If `-b` is ever
dropped from `/etc/default/gpsd`, this becomes the mechanism by which gpsd starts
rewriting the BBR config. Another reason it stays.

Then open the port and add the target:

```bash
sudo ufw allow from <prometheus-ip> to any port 9016 proto tcp comment 'prometheus'
```

#### Metrics and value mappings

Gauges are numeric, matching how `gpsd_mode` is handled above — put the labels in
Grafana value mappings, not in the exporter.

| Metric | Meaning |
|---|---|
| `gnss_rf_antenna_status` | `0` init, `1` unknown, `2` OK, `3` short, `4` open |
| `gnss_rf_antenna_power` | `0` off, `1` on, `2` unknown |
| `gnss_rf_jamming_state` | `0` unknown/disabled, `1` OK, `2` warning, `3` critical |
| `gnss_rf_jamming_indicator` | CW indicator, 0–255 |
| `gnss_rf_agc_count` / `_ratio` | AGC monitor, 0–8191 and the same as a fraction |
| `gnss_rf_noise_per_ms` | Broadband noise level |
| `gnss_rf_post_status` | Self-test word, nonzero is a fault |
| `gnss_rf_iq_offset_*`, `_magnitude_*` | I/Q imbalance |
| `gnss_rf_last_frame_timestamp_seconds` | Freshness — see below |

The MAX-M10S is single-band, so every series carries `block="0"`. The `block`
label exists because MON-RF is defined per RF path and a multi-band module would
report several.

**Read the absolute numbers as a baseline, not a threshold.** `noise_per_ms` and
`agc_count` have no universal good value — they depend on this antenna, this cable
and this site. Let a week of history accumulate, then alert on departure from the
observed band rather than on a number taken from a datasheet.

First readings, 2026-08-20, as the starting point for that band:

| Metric | Value |
|---|---|
| `jamming_state` | 1 (OK) |
| `jamming_indicator` | 14 / 255 |
| `noise_per_ms` | 86–87 |
| `agc_count` | 1488 / 8191 (18 %) |
| `antenna_status` / `antenna_power` | 2 (OK) / 1 (on) |
| `post_status` | 0 |
| I/Q magnitude I, Q | 156, 156 (offsets 10, 9) |

Balanced I/Q magnitudes and an AGC sitting low in its range are what a clean
front end looks like; AGC climbing while `jamming_indicator` rises is the
signature to watch for.

#### Alerting

`gnss_rf_jamming_state >= 2` is the one worth mailing on, and it leads PPS
degradation rather than following it — which is the entire point of collecting
this. Add `gnss_rf_antenna_status != 2` alongside it only if the field turns out
to be live on this board; see the caveat above.

Every gauge here is push-driven, so a stalled stream leaves the last good value
in place and looks healthy forever. Staleness needs its own rule:

```
time() - gnss_rf_last_frame_timestamp_seconds > 60
```

`gnss_rf_up < 1` is not a substitute: it covers the gpsd socket only, and the
module can stop emitting MON-RF — a BBR loss after a long power-off, say — while
gpsd stays perfectly connected.

## Prometheus recording rule

Dashboard 19186's "Maximum clock error" panel queries a recorded series the
exporter does not emit. Without this rule the panel reads *No Data*.

`/etc/prometheus/rules/chrony.yml`:

```yaml
groups:
  - name: Chrony
    rules:
      - record: instance:chrony_clock_error_seconds:abs
        expr: >
          abs(chrony_tracking_last_offset_seconds)
          +
          chrony_tracking_root_dispersion_seconds
          +
          (0.5 * chrony_tracking_root_delay_seconds)
```

Referenced from `prometheus.yml` under `rule_files:`. Recording rules do not
backfill, so the panel stays empty until an evaluation cycle has run.

## Dashboards

- chrony: [`dashboards/chrony.json`](dashboards/chrony.json), with the edits
  below already applied.
- gpsd: [`dashboards/gpsd.json`](dashboards/gpsd.json), with the edits below
  already applied.
- node_exporter: Grafana dashboard ID **1860**

Import the two JSON files via Dashboards → New → Import → Upload JSON. They are
exported in Grafana's v2 dashboard schema (`dashboard.grafana.app/v2`), which
Grafana versions limited to the classic JSON model cannot import; on those,
start from the upstream dashboards — ID **19186** for chrony,
`gpsd_grafana_dashboard.json` at the root of the gpsd-prometheus-exporter clone
for gpsd — and apply the edits by hand.

`dashboards/chrony.json` is a modified version of Grafana dashboard
[19186](https://grafana.com/grafana/dashboards/19186-chrony/) by equinox0815.

`dashboards/gpsd.json` is a modified copy of the dashboard shipped with
[gpsd-prometheus-exporter](https://github.com/brendanbank/gpsd-prometheus-exporter),
Copyright (c) 2023 Brendan Bank, used under the BSD 3-Clause License in
[`dashboards/LICENSE.gpsd-prometheus-exporter`](dashboards/LICENSE.gpsd-prometheus-exporter).

### Post-import edits

Re-importing an upstream dashboard discards all of the following. Save under a
new name to keep them.

**chrony 19186 — sources table shows NMEA as `unreach`.** Chrony has no state
for "excluded by `noselect`" and falls back to `?`, which the exporter passes
through as `unreach`. NMEA is healthy; `chrony_sources_reachability_success`
reads 1. Rewrite the label for that one source:

```
label_replace(chrony_sources_state_info{instance="$instance"}, "source_state", "coarse time only", "source_name", "NMEA")
```

Non-matching series pass through untouched, so a genuinely unreachable NTP
server still reports `unreach`. Do not filter NMEA out of the panel instead —
that hides the source `kPPS` depends on for its lock.

The two NTP servers showing `outlier` is also correct: kPPS is `prefer` and
several orders of magnitude better, so the combining algorithm excludes them.

**chrony 19186 — added "Hardware TX timestamp ratio" panel.** Time series, Unit
→ **Percent (0.0-1.0)**, legend `HW TX ratio`. See
[Client-side timestamping](#client-side-timestamping) for why all three counters
are in the denominator:

```
rate(chrony_serverstats_ntp_hw_tx_timestamps_total[5m])
/
(
  rate(chrony_serverstats_ntp_hw_tx_timestamps_total[5m])
  + rate(chrony_serverstats_ntp_daemon_tx_timestamps_total[5m])
  + rate(chrony_serverstats_ntp_kernel_tx_timestamps_total[5m])
)
```

**gpsd dashboard — three PPS panels have no data**, since gpsd never sees
`/dev/pps0`. Rebuilt on chrony's kPPS measurements, which are more precise
anyway:

| Panel | Change |
|---|---|
| Clock offset from PPS | Heatmap → **Time series**, query `chrony_sources_last_sample_offset_seconds{source_name="kPPS"}` |
| (±) 0.95 Percentile | 3 queries → `quantile_over_time($percentiles, ...[1h])`, `quantile_over_time(0.5, ...)`, `quantile_over_time((1 - $percentiles), ...)`, legends `upper`/`median`/`lower` |
| GPS Details | disable the third query (`gpsd_pps_histogram_bucket`) — one empty query blanks the whole table join |

Drop `$instance` and `$device` from these queries. Those variables resolve to the
gpsd exporter on `:9015` and would not match chrony series on `:9123`, and chrony
has no `device` label. Set Unit → **seconds (s)** so values render as ns.

Disabling the GPS Details query leaves dead space in that panel. Filled with a
**Timing Status** stat panel: `chrony_sources_last_sample_offset_seconds`,
`chrony_sources_last_sample_error_margin_seconds` (both `source_name="kPPS"`) and
`chrony_tracking_stratum`.

**gpsd dashboard — fix status panel.** `gpsd_status` reads 0 and is not a fault:
gpsd only populates that field for augmented fixes (DGPS, RTK, DR, surveyed), and
omits it for an ordinary one, leaving the gauge at its initial 0. Use `gpsd_mode`
instead and replace the inherited value mappings, which are on the `gpsd_status`
scale and would render mode 3 as "RTK Fixed Point":

`0` → No mode yet, `1` → No fix, `2` → 2D fix, `3` → 3D fix

**Geo offset panels** need `--offset-from-geopoint --geopoint-lat --geopoint-lon`
in `gpsd_exporter.service`. Use a surveyed average such as
`avg_over_time(gpsd_lat[6h])`, not a single instantaneous reading, or the offset
is centred on that one sample's error.

## Alerting

Rules live in Grafana, not Prometheus. Both evaluate the same PromQL, but
Prometheus alerts cannot notify anything on their own — they surface only in the
Prometheus UI unless Alertmanager is run as a separate service. Grafana already
has SMTP configured, so it evaluates and emails from one place. Prometheus keeps
only the recording rule.

`grafana-alerts.yml` provisions ten rules into an `NTP` folder. It installs on the
Grafana host as `/etc/grafana/provisioning/alerting/ntp.yml` — **the deployed name
differs from the name here**, so copying it across without renaming creates a
second file declaring the same group and the same rule UIDs, which Grafana will
reject or resolve arbitrarily. Overwrite `ntp.yml`, then restart. The file ships
with `PROMETHEUS_DATASOURCE_UID` as a placeholder; replace every occurrence with
the UID of that Grafana's Prometheus datasource (Connections > Data sources >
Prometheus, UID is in the URL) before installing. Provisioned rules are read-only
in the UI; edit the file and restart to change them.

Firing a rule does not send mail by itself. Alerting > Notification policies >
Default policy must point at the Email contact point.

The SMTP password does not belong in `grafana.ini`. Grafana's file provider
keeps it out:

```ini
password = $__file{/etc/grafana/smtp_password}
```

with the file `chmod 640 root:grafana` and containing the password and nothing
else — no trailing newline, or auth fails silently. This is not encryption;
`$__vault{}` is Grafana Enterprise only.

The alert worth understanding is **Chrony control socket unreachable**
(`chrony_up < 1`). The exporter keeps serving HTTP when it cannot reach chronyd,
so the scrape succeeds and Prometheus `up` stays 1. Nothing else catches it.

Thresholds are starting points. `Clock error bound above 1ms` is deliberately
loose — a healthy kPPS stratum 1 sits in the low hundreds of ns — so retune it
down once a few weeks of history exist.

## Client-side timestamping

The server was already configured for this (`hwtimestamp *` in chrony.conf), but
the gain is only realised when clients ask for it. Verify from any client with
`chronyc ntpdata time.example.com`.

**Both options are needed, and they do different things.**

`xleave` on the client's server line enables interleaved mode, which is what lets
the *server* report a hardware transmit timestamp:

```
server time.example.com iburst xleave
```

`hwtimestamp <interface>` in the client's chrony.conf enables the *client's* own
NIC timestamping. Without it the client stays on kernel timestamps even with
interleaved mode negotiated. On a bond, list each physical interface so it
survives failover.

Watch `chrony_serverstats_ntp_hw_tx_timestamps_total` climb on the Pi as clients
convert. The three TX counters are mutually exclusive and sum to total responses,
so a true fraction needs all three in the denominator, not just the daemon one —
dividing by `daemon_tx` alone diverges as that term approaches zero.

**The `all` receive filter is what NTP needs.** `ethtool -T` lists the receive
filter modes a NIC supports. Hardware RX timestamping of NTP requires `all`;
the `ptpv2-*` filters match only PTP packets, and NTP is not PTP. A NIC offering
a full PTP filter set but no `all` will do hardware TX and kernel RX, and no
configuration changes that. Transmit needs no filter, which is why TX works
everywhere.

So the better NIC for PTP can be the worse NIC for NTP. Check `ethtool -T` per
interface rather than assuming the higher-end card wins.

`chronyc ntpdata` reports the *last* packet's mode in the `TX/RX timestamping`
lines while `Total HW TX`/`Total HW RX` are cumulative. Occasional kernel
fallback is normal; judge by the totals.

**Results.** Flat-network clients reach roughly -100ns offset with ~20us peer
delay. Clients routed across VLANs through OPNsense sit near -50us with ~165us
peer delay — the router's forwarding asymmetry, which NTP cannot compensate for
and hardware timestamping does not address. OPNsense cannot help here either:
chrony's `hwtimestamp` is Linux-only, FreeBSD NIC drivers largely do not expose
hardware timestamping, and `ptpd` does not support it at all.

Windows clients gain nothing from any of this. `w32time` has no interleaved mode
and no hardware timestamping on its NTP path; Windows exposes NIC timestamping
only for PTPv2 over UDP, and only with vendor drivers.

Proxmox LXC containers share the host clock and cannot set time, so they inherit
the host's accuracy. Do not run chrony inside them. VMs have their own clock and
do need it.

## Notes for this install

**PPS quality comes from chrony, not gpsd.** `/dev/pps0` is intentionally absent
from gpsd's `DEVICES`, so gpsd emits no PPS or TOFF reports and
`--pps-histogram` would graph nothing. The authoritative numbers are
chrony_exporter's source metrics for the `kPPS` refclock, since chrony is the
process actually consuming the kernel PPS.

**Both refclocks appear separately.** `NMEA` (the SOCK refclock, `noselect`) and
`kPPS` show up as distinct sources, so PPS jitter can be plotted independently
of the coarse NMEA time. Watch for `kPPS` losing its `lock NMEA` association —
that is the failure mode worth alerting on.

**Frequency vs. temperature.** Plot `chrony_tracking_frequency_ppms` against
temperature on a shared time axis.

Tempcomp is disabled — the March 2026 testing found its correction noise
exceeded the thermal drift it was compensating for. So this panel is not
validating a live table; it is the standing evidence for that decision, and the
thing that would show if drift ever grew enough to revisit it.

Use the CPU thermal zone:

```
node_thermal_zone_temp{type="cpu-thermal"}
```

That is `hwmon0` (`cpu_thermal`), the sensor `tempcomp` and
`collect_tempcomp_data.sh` read. The Pi 5's other hwmon chips are `rp1_adc`
and `rpi_volt`; the ADC runs ~5 °C hotter and would shift the curve.

**Firewall.** The exporters bind all interfaces and chrony's own `allow` rules do
not cover them, so ufw needs the Prometheus host opened per port:

```bash
sudo ufw allow from <prometheus-ip> to any port 9123 proto tcp comment 'prometheus'
```

Repeat for 9015 and 9100. In the `from ... to ...` form ufw requires the `port`
keyword and `proto tcp` — the `9123/tcp` shorthand only works in the short
`ufw allow 9123/tcp` form. No Prometheus restart is needed once the ports open;
targets go `UP` on the next scrape.
