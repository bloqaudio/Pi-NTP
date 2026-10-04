#!/bin/bash
# MAX-M10S NTP Timing Configuration Script
# Configures the u-blox MAX-M10S for optimal stratum 1 NTP performance
#
# Hardware: u-blox MAX-M10S on Uputronics 5V breakout board
# Firmware: ROM SPG 5.10, Protocol 34.10
# Platform: Raspberry Pi 5, Ubuntu 24.04
#
# Wiring (5V Uputronics board to Pi 5 GPIO header):
#   VCC -> Pin 4 (5V)
#   GND -> Pin 6
#   TX  -> Pin 10 (GPIO 15 / Pi RX)
#   RX  -> Pin 8  (GPIO 14 / Pi TX)
#   TP  -> Pin 12 (GPIO 18 / PPS)
#
# Usage: sudo bash configure_m10s.sh
#
# Notes:
#   - ubxtool 3.25 string key names work for VALSET on M10S
#   - Do NOT use -p CFG-VALSET syntax; use -z KEY,VALUE,LAYER directly
#   - The VALSET layer is a BITMASK: RAM=1, BBR=2, Flash=4 (M10S has no flash).
#     We use 3 (RAM+BBR) so config takes effect immediately AND persists across
#     power cycles, per the integration manual (UBX-20053088 sec. 2): "recommended
#     to apply runtime configuration on both RAM and battery-backed RAM (BBR)".
#     NOTE: BBR is only retained while the board's 0.2F backup supercap holds
#     charge (~hours, not weeks). For guaranteed persistence this script is also
#     run on every boot via the gps-m10s-config.service systemd unit BEFORE gpsd.
#   - NMEA message trimming via CFG-MSGOUT-NMEA_ID_*_UART1 caused NMEA
#     output to stop entirely in testing — avoid until root cause understood
#   - COLDBOOT / RESET commands wipe BBR config — do not use after configuring
#   - cat /dev/ttyAMA0 requires raw mode: stty -F /dev/ttyAMA0 <baud> raw -echo

set -euo pipefail

DEV="/dev/ttyAMA0"
PROTVER="34.10"
# VALSET layer bitmask: RAM=1, BBR=2, Flash=4. Use RAM+BBR so settings apply
# now and survive power cycles (while the backup supercap holds charge).
LAYER="3"

echo "=== MAX-M10S NTP Timing Configuration ==="
echo ""

# Stop gpsd ONLY if it is actually running, and remember that we did.
# Never call "systemctl stop" on gpsd at boot: with gpsd queued behind this
# unit (After= ordering), a stop request DELETES the pending start job and
# gpsd never starts. is-active is false for queued-but-not-started units,
# so this guard makes the boot path a no-op.
echo "[1/8] Checking gpsd..."
RESTART_GPSD=0
if systemctl is-active --quiet gpsd.service || systemctl is-active --quiet gpsd.socket; then
    echo "  Stopping gpsd for exclusive serial port access..."
    systemctl stop gpsd.service gpsd.socket 2>/dev/null || true
    RESTART_GPSD=1
    sleep 2
else
    echo "  gpsd not running; skipping stop"
fi

# Restart gpsd on ANY exit (success or failure) if we stopped it, so a
# failed run never leaves the time service down.
# --no-block: when this script runs as gps-m10s-config.service, gpsd is
# ordered After us, so a blocking start would deadlock until timeout.
restore_gpsd() {
    if [ "$RESTART_GPSD" = "1" ]; then
        echo "Queueing gpsd restart..."
        systemctl start --no-block gpsd.socket gpsd.service 2>/dev/null || true
    fi
}
trap restore_gpsd EXIT

# Verify module responds. Probe 115200 first (the configured steady state),
# then 9600 (module firmware default after a BBR wipe). Retry the pair a few
# times: a single-pass probe raced with early-boot serial activity on
# 2026-07-05 and failed spuriously (module was fine seconds later).
echo "[2/8] Verifying module communication..."
BAUD=""
RESPONSE=""
for attempt in 1 2 3; do
    for try_baud in 115200 9600; do
        # || true: a probe at the wrong baud times out and ubxtool exits
        # non-zero; we decide success via grep, so don't let set -e abort.
        RESPONSE=$(ubxtool -p MON-VER -f "$DEV" -s "$try_baud" -P "$PROTVER" 2>&1 || true)
        if echo "$RESPONSE" | grep -q "MAX-M10S"; then
            BAUD="$try_baud"
            break 2
        fi
    done
    echo "  Attempt ${attempt}/3 failed at both baud rates, retrying in 3s..."
    sleep 3
done
if [ -n "$BAUD" ]; then
    echo "  Module found at ${BAUD} baud"
else
    echo "  ERROR: Cannot communicate with module at 9600 or 115200"
    echo "  Last ubxtool output:"
    echo "$RESPONSE" | head -10
    exit 1
fi

# Baud rate — set to 115200 for lower serial latency
echo "[3/8] Setting baud rate to 115200..."
if [ "$BAUD" != "115200" ]; then
    ubxtool -z CFG-UART1-BAUDRATE,115200,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
    sleep 1
    BAUD="115200"
    # Verify baud change took effect
    # || true: a probe at the wrong baud times out and ubxtool exits non-zero;
# we decide success via grep below, so don't let set -e abort here.
RESPONSE=$(ubxtool -p MON-VER -f "$DEV" -s "$BAUD" -P "$PROTVER" 2>&1 || true)
    if echo "$RESPONSE" | grep -q "MAX-M10S"; then
        echo "  Baud rate changed to 115200"
    else
        echo "  ERROR: Module not responding at 115200 after baud change"
        exit 1
    fi
else
    echo "  Already at 115200"
fi

# Stationary dynamic model — antenna is fixed, optimize for timing
# From integration manual section 2.2.1: "Used in timing applications
# (antenna must be stationary) or other stationary applications.
# Velocity restricted to 0 m/s. Zero dynamics assumed."
echo "[4/8] Setting stationary dynamic model..."
ubxtool -z CFG-NAVSPG-DYNMODEL,2,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
# Verify
RESPONSE=$(ubxtool -g CFG-NAVSPG-DYNMODEL -f "$DEV" -s "$BAUD" -P "$PROTVER" 2>&1 || true)
if echo "$RESPONSE" | grep -q "val 2"; then
    echo "  Dynamic model set to Stationary (2)"
else
    echo "  WARNING: Could not verify dynamic model setting"
fi

# Time pulse configuration — align PPS to UTC grid
# From integration manual section 3.9.2:
#   TIMEGRID_TP1: 0=UTC, 1=GPS, 2=GLONASS, 3=BeiDou, 4=Galileo, 5=NAVIC
#   ALIGN_TO_TOW: aligns pulses to top of second
echo "[5/8] Configuring time pulse for UTC alignment..."
ubxtool -z CFG-TP-TIMEGRID_TP1,0,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
ubxtool -z CFG-TP-ALIGN_TO_TOW_TP1,1,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
echo "  Time pulse grid set to UTC, aligned to top of second"

# Antenna cable delay compensation
# Bingfu active GPS antenna with 3m RG174 cable (no pigtail extension)
# RG174 velocity factor ~66%, 3m / (0.66 * 299792458 m/s) = ~15 ns
# Default is 50 ns which adds 35 ns error to PPS timing
echo "[6/8] Setting antenna cable delay to 15 ns..."
ubxtool -z CFG-TP-ANT_CABLEDELAY,15,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
# Verify
RESPONSE=$(ubxtool -g CFG-TP-ANT_CABLEDELAY -f "$DEV" -s "$BAUD" -P "$PROTVER" 2>&1 || true)
if echo "$RESPONSE" | grep -q "val 15"; then
    echo "  Cable delay set to 15 ns"
else
    echo "  WARNING: Could not verify cable delay setting"
fi

# Enable jamming/interference monitor
# Detects and reports RF interference near the GNSS band
echo "[7/8] Enabling jamming/interference monitor..."
ubxtool -z CFG-ITFM-ENABLE,1,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
RESPONSE=$(ubxtool -g CFG-ITFM-ENABLE -f "$DEV" -s "$BAUD" -P "$PROTVER" 2>&1 || true)
if echo "$RESPONSE" | grep -q "val 1"; then
    echo "  Jamming monitor enabled"
else
    echo "  WARNING: Could not verify jamming monitor setting"
fi

# UBX-MON-RF output — feeds the RF/interference exporter on port 9016.
# gpsd holds the port exclusively and runs read-only (-b), so nothing on the
# Pi can poll for this; the module has to push it. Rate is in navigation
# epochs, so 5 is every 5 s at the 1 Hz nav rate (36 bytes, negligible).
echo "[8/8] Enabling UBX-MON-RF output..."
ubxtool -z CFG-MSGOUT-UBX_MON_RF_UART1,5,"$LAYER" -f "$DEV" -s "$BAUD" -P "$PROTVER"
RESPONSE=$(ubxtool -g CFG-MSGOUT-UBX_MON_RF_UART1 -f "$DEV" -s "$BAUD" -P "$PROTVER" 2>&1 || true)
if echo "$RESPONSE" | grep -q "val 5"; then
    echo "  MON-RF output enabled at 5 s"
else
    echo "  WARNING: Could not verify MON-RF output setting"
fi

# Verify NMEA output is still flowing
echo ""
echo "Verifying NMEA output..."
# tr -d strips the null bytes in the UBX-MON-RF frames now sharing this
# stream; command substitution warns about them and drops them anyway.
NMEA=$(stty -F "$DEV" "$BAUD" raw -echo && timeout 3 cat "$DEV" 2>/dev/null | tr -d "\0" || true)
if echo "$NMEA" | grep -q "GNRMC\|GNGGA"; then
    echo "  NMEA output confirmed"
else
    echo "  WARNING: No NMEA output detected — check module"
fi

echo ""
echo "=== Configuration Complete ==="
echo ""
echo "Module configuration (stored in BBR):"
echo "  Baud rate:       115200"
echo "  Dynamic model:   Stationary (timing optimized)"
echo "  Time pulse:      UTC grid, aligned to TOW"
echo "  Cable delay:     15 ns (3m RG174)"
echo "  Jamming monitor: Enabled"
echo "  MON-RF output:   Every 5 s on UART1 (interference exporter)"
echo "  Constellations:  GPS + Galileo + BeiDou B1I + QZSS + SBAS (firmware defaults)"
echo "  GLONASS:         Disabled (firmware default — incompatible with BeiDou B1I)"
echo ""
echo "Pi configuration required:"
echo "  /etc/default/gpsd:       GPSD_OPTIONS=\"-n -b -s 115200\""
echo "                           DEVICES=\"/dev/ttyAMA0\""
echo "  /boot/firmware/config.txt: init_uart_baud=115200"
echo ""
echo "gpsd is restarted automatically if this script stopped it (see trap)."
