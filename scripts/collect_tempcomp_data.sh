#!/bin/bash
# Collect temperature vs frequency data for chrony tempcomp generation.
# Run for at least 24 hours to capture a full temperature cycle.
#
# Samples CPU temperature (hwmon) and chrony frequency offset every 20 seconds.
# Output format matches tempcomp_gen.py input: Time;Frequency;Temperature
#
# Usage:
#   sudo bash collect_tempcomp_data.sh [output_file] [duration_hours]
#   sudo bash collect_tempcomp_data.sh                    # 24h, plot_data.txt
#   sudo bash collect_tempcomp_data.sh mydata.txt 48      # 48h, mydata.txt
#
# Prerequisites:
#   - chrony running with tempcomp DISABLED
#   - kPPS selected as reference source (chronyc tracking shows kPPS)
#
# Stop early with Ctrl+C — partial data is still usable if it covers
# enough of the temperature range.

set -euo pipefail

OUTFILE="${1:-plot_data.txt}"
DURATION_HOURS="${2:-24}"
INTERVAL=20
SENSOR="/sys/class/hwmon/hwmon0/temp1_input"

# Validate sensor exists
if [ ! -f "$SENSOR" ]; then
    echo "ERROR: Temperature sensor not found at $SENSOR"
    echo "Find yours with:"
    echo '  for d in /sys/class/hwmon/hwmon*; do echo "$d: $(cat $d/name) = $(cat $d/temp*_input 2>/dev/null)"; done'
    exit 1
fi

# Validate chrony is running and kPPS is selected
if ! chronyc sources 2>/dev/null | awk '$1 ~ /^#\*/ && $2 == "kPPS" {found=1} END {exit found ? 0 : 1}'; then
    echo "WARNING: kPPS is not currently the selected source"
    echo "Data quality may be poor without stable PPS discipline"
fi

TOTAL_SAMPLES=$(( DURATION_HOURS * 3600 / INTERVAL ))

echo "Collecting temperature vs frequency data"
echo "  Output:   $OUTFILE"
echo "  Sensor:   $SENSOR"
echo "  Interval: ${INTERVAL}s"
echo "  Duration: ${DURATION_HOURS}h (~${TOTAL_SAMPLES} samples)"
echo "  Requirement: tempcomp must stay disabled while collecting"
echo "  Ctrl+C to stop early"
echo ""

# Write header
echo "Time;Frequency;Temperature" > "$OUTFILE"

COUNT=0
while [ "$COUNT" -lt "$TOTAL_SAMPLES" ]; do
    TIME=$(date +%H:%M:%S)
    FREQ_LINE=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Frequency/ {print $2}')
    FREQ=$(printf '%s\n' "$FREQ_LINE" | awk '{print $1}')
    # Negate if "slow" (chrony reports "X ppm slow" or "X ppm fast")
    DIRECTION=$(printf '%s\n' "$FREQ_LINE" | awk '{print $3}')
    if [ -z "$FREQ" ] || [ -z "$DIRECTION" ]; then
        echo "ERROR: Could not parse chronyc Frequency line: $FREQ_LINE" >&2
        exit 1
    fi
    if [ "$DIRECTION" = "slow" ]; then
        FREQ="-${FREQ}"
    fi
    TEMP_MILLI=$(cat "$SENSOR")
    TEMP=$(echo "scale=3; $TEMP_MILLI / 1000" | bc)

    echo "${TIME};${FREQ};${TEMP}" >> "$OUTFILE"
    COUNT=$((COUNT + 1))

    if [ $((COUNT % 180)) -eq 0 ]; then
        HOURS_DONE=$(echo "scale=1; $COUNT * $INTERVAL / 3600" | bc)
        echo "  ${HOURS_DONE}h elapsed, ${COUNT} samples collected (temp: ${TEMP}C, freq: ${FREQ} ppm)"
    fi

    sleep "$INTERVAL"
done

echo ""
echo "Collection complete: ${COUNT} samples in $OUTFILE"
echo "Generate tempcomp table with:"
echo "  python3 scripts/tempcomp_gen.py $OUTFILE"
