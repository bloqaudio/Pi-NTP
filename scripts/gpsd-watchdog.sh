#!/bin/bash
# gpsd-watchdog.sh
# Monitors chrony's NMEA source and restarts gpsd if it goes stale.
# Run via cron every 5 minutes as root.
#
# Install:
#   sudo cp scripts/gpsd-watchdog.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/gpsd-watchdog.sh
#   sudo crontab -e
#   */5 * * * * /usr/local/bin/gpsd-watchdog.sh

NMEA_REACH=$(chronyc sources 2>/dev/null | grep NMEA | awk '{print $5}')

if [ -z "$NMEA_REACH" ]; then
    logger -t gpsd-watchdog "NMEA source not found in chrony, skipping"
    exit 0
fi

if [ "$NMEA_REACH" = "0" ]; then
    logger -t gpsd-watchdog "NMEA reach is 0, restarting gpsd"
    systemctl restart gpsd
else
    exit 0
fi
