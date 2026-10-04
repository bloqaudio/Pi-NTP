# Pi-NTP

GPS-disciplined Stratum 1 NTP server on a Raspberry Pi (or any Linux SBC with UART and GPIO).

A sub-microsecond accurate time server built from a ~$30 GPS module and a Raspberry Pi, serving stratum 1 time to your local network. This outperforms the time infrastructure at most enterprise environments.

This directory is the canonical config/documentation set. Top-level files in the parent folder are working notes and local copies.

## Architecture

This setup uses a three-layer time source hierarchy:

1. **PPS (Pulse Per Second)** - The primary time source. The GPS module emits a hardware pulse precisely on each second boundary, accurate to nanoseconds. PPS tells chrony *exactly* when the second starts, but not *which* second it is.

2. **GPS NMEA** - Coarse time from satellite data. The GPS module streams NMEA sentences over serial (115200 baud on the MAX-M10S), providing date, time, and position. This data has ~100-200ms of latency due to serial parsing, making it useless for precision timing. Its only job is to tell chrony which second the PPS pulse belongs to.

3. **Network NTP (fallback)** - Cloudflare and Ubuntu pool servers provide sanity-checking and coarse time when GPS has no fix (cold start, antenna issues, indoor operation).

The daemon chain: `gpsd` reads NMEA from `/dev/ttyAMA0` and delivers coarse time to `chrony` via a Unix socket (SOCK protocol). `chrony` reads PPS directly from `/dev/pps0` via the kernel, completely independent of gpsd. gpsd has a [documented bug](https://gitlab.com/gpsd/gpsd/-/issues/181) where it can silently stop delivering time to chrony on long-running instances. It affects both the SHM and SOCK outputs and was fixed upstream after the 3.25 release; a watchdog restarts gpsd when it happens.

As of March 25, 2026, the tested Pi 5 / Ubuntu 24.04 / gpsd 3.25 build is using `/run/chrony.ttyAMA0.sock` successfully with `offset 0.000`. Upstream gpsd documentation is inconsistent about chrony socket naming, so treat that path as tested behavior on this build, not a universal rule. Verify on your host with `chronyc sourcestats -v`, `journalctl -u gpsd`, and the presence of the expected socket in `/run`.

### What this achieves

```
$ chronyc tracking
Reference ID    : 6B505053 (kPPS)
Stratum         : 1
System time     : 0.000000037 seconds fast of NTP time
Last offset     : +0.000000012 seconds
RMS offset      : 0.000000181 seconds
Frequency       : 0.442 ppm slow
Residual freq   : +0.000 ppm
Skew            : 0.005 ppm

$ chronyc sources
#? NMEA    0   4   377    23   +142ns[ +152ns] +/-  200ms
#* kPPS    0   4   377    14    +31ns[  +42ns] +/-  114ns

$ chronyc sourcestats -v
NMEA    15   9   224     -0.000      0.005    -46ns   289ns
kPPS    15   8   225     +0.000      0.005     +0ns   300ns
```

Sub-microsecond accuracy with nanosecond-level precision. 37ns system offset, 181ns RMS, 0.005 ppm skew.

## Hardware

### Bill of materials

| Part | Notes |
|------|-------|
| Linux SBC | Any board with a UART and a GPIO pin that supports edge interrupts (Raspberry Pi, Orange Pi, ODROID, etc.). Tested on a Raspberry Pi 5 with Ubuntu 24.04. |
| u-blox MAX-M10S GPS module | Recommended: Uputronics MAX-M10S breakout with active antenna support. Any module with PPS output works (u-blox NEO-6M, NEO-M8N, ATGM336H, etc.) but u-blox modules are recommended for best gpsd compatibility. |
| GPS antenna | Active or passive, needs sky view. Active antenna recommended for the M10S. |
| 5x jumper wires | Female-to-female for GPIO header connection |
| Soldering iron (maybe) | Some GPS modules ship without header pins soldered. If yours has bare through-holes, you'll need to solder on pins or wires before connecting to the Pi's GPIO header. |

### GPIO wiring

```
MAX-M10S (Uputronics)   Raspberry Pi 5 (GPIO Header)
─────────────────────   ──────────────────────────────
VCC  ─────────────────── Pin 4   (5V Power)
GND  ─────────────────── Pin 6   (Ground)
TX   ─────────────────── Pin 10  (GPIO 15 / UART0 RX)
RX   ─────────────────── Pin 8   (GPIO 14 / UART0 TX)
TP   ─────────────────── Pin 12  (GPIO 18 / PPS)
```

TX connects to RX and RX connects to TX. This is intentional - it's a crossover, not a mistake.

Pin 12 (GPIO 18) is the default pin expected by the `pps-gpio` device tree overlay.

## Setup

### Prerequisites

Ubuntu 24.04 LTS (tested on Raspberry Pi 5, should work on other distributions and SBCs with appropriate adjustments to boot config paths).

### 1. Boot configuration

Edit `/boot/firmware/config.txt` and add:

```
# Pi 5 specific: enable UART0 console and overlay on GPIO 14/15
dtparam=uart0_console=on
dtoverlay=uart0-pi5

# Enable UART0 for GPS serial data
enable_uart=1

# Set UART baud rate (9600 for factory default, 115200 after M10S config)
init_uart_baud=115200

# Enable PPS input on GPIO 18
dtoverlay=pps-gpio,gpiopin=18

# Free UART0 from Bluetooth
dtoverlay=disable-bt

# Headless optimizations - reduce jitter from unnecessary subsystems
gpu_mem=16
dtparam=audio=off
```

Edit `/boot/firmware/cmdline.txt`:
- **Remove** `console=serial0,115200` (or `console=ttyAMA0,115200`). This prevents the kernel from claiming the UART for console output. Leave `console=tty1` in place.
- **Add** `noswap` after `rootfstype=ext4` to disable swap, reducing unnecessary I/O latency.

Reboot.

### 2. Verify hardware

After reboot, confirm the devices exist:

```bash
ls /dev/ttyAMA0 /dev/pps0
```

Test PPS:

```bash
sudo apt install pps-tools
sudo ppstest /dev/pps0
```

You should see assertions at 1-second intervals. If the GPS module doesn't have a satellite fix yet, PPS won't fire - give it sky view and a few minutes for cold start.

Test NMEA:

```bash
stty -F /dev/ttyAMA0 9600 raw -echo && cat /dev/ttyAMA0
```

You should see NMEA sentences (`$GNRMC`, `$GNGGA`, etc.). Note: `raw -echo` mode is required for `cat` to display serial data. The default baud is 9600; after running the M10S configuration script it will be 115200.

### 3. Install packages

```bash
sudo apt install gpsd gpsd-clients chrony setserial
```

### 4. System tuning

These steps reduce jitter and latency by eliminating unnecessary system activity. This is a headless time server - strip it down to essentials.

**Disable conflicting and unnecessary services:**

```bash
sudo systemctl disable --now systemd-timesyncd
sudo systemctl disable --now avahi-daemon.service
sudo systemctl disable --now bluetooth.service
sudo systemctl disable --now wpa_supplicant.service
sudo systemctl disable --now triggerhappy.service
sudo systemctl disable --now alsa-restore.service alsa-state.service alsa-utils.service
```

Not all of these will exist on every installation. Errors for missing services are harmless.

**Remove modemmanager** (if installed):

```bash
sudo apt remove --purge modemmanager -y && sudo apt autoremove --purge -y
```

**Give chrony higher scheduling priority** (use a systemd override, not direct editing):

```bash
sudo mkdir -p /etc/systemd/system/chrony.service.d
sudo tee /etc/systemd/system/chrony.service.d/override.conf << 'EOF'
[Service]
Nice=-10
EOF
sudo systemctl daemon-reload
sudo systemctl restart chrony
```

**Auto-restart on kernel panic** (safety net for unattended server):

```bash
echo "kernel.panic = 10" | sudo tee /etc/sysctl.d/90-kernelpanic-reboot.conf
```

**Reduce ethernet coalescence** to improve NTP response latency to LAN clients (~40us improvement):

```bash
sudo ethtool -C eth0 tx-usecs 4 rx-usecs 4
```

To persist this across reboots, create a systemd service:

```bash
sudo tee /etc/systemd/system/eth-coalesce.service << 'EOF'
[Unit]
Description=Configure Ethernet Coalesce for NTP
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -C eth0 tx-usecs 4 rx-usecs 4

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now eth-coalesce.service
```

### 5. Reduce serial latency

Create a udev rule to set the serial port to low-latency mode, reducing NMEA jitter:

```bash
echo 'KERNEL=="ttyAMA0", RUN+="/bin/setserial /dev/ttyAMA0 low_latency"' | sudo tee /etc/udev/rules.d/gps.rules
```

### 6. Configure the GPS module (u-blox MAX-M10S)

If using the u-blox MAX-M10S, run the configuration script to set the baud rate, stationary dynamic model, and UTC-aligned time pulse. This requires gpsd to be stopped:

```bash
sudo systemctl stop gpsd gpsd.socket
sudo bash scripts/configure_m10s.sh
```

The script stores settings in the module's battery-backed RAM (BBR), which persists across power cycles as long as the backup battery holds. See [`scripts/configure_m10s.sh`](scripts/configure_m10s.sh) for details.

### 7. Configure gpsd

```bash
sudo cp configs/gpsd /etc/default/gpsd
```

This configures gpsd to read NMEA from the GPS module. Only `/dev/ttyAMA0` is listed; chrony reads PPS directly from `/dev/pps0` via the kernel, independent of gpsd. Key flags:

| Flag | Purpose |
|------|---------|
| `-n` | Start polling immediately at boot, don't wait for a client to connect |
| `-b` | Read-only mode - don't send commands to the GPS module (preserves our UBX config) |
| `-s 115200` | Baud rate matching the M10S configuration (9600 if using factory defaults) |

Remote gpsd access is disabled by default. Add `-G` only if you explicitly need remote gpsd clients.

See [`configs/gpsd`](configs/gpsd) for the full annotated config.

### 8. Configure chrony

```bash
sudo cp configs/chrony.conf /etc/chrony/chrony.conf
```

The critical lines are the two refclock directives:

```
refclock SOCK /run/chrony.ttyAMA0.sock refid NMEA offset 0.000 precision 1e-1 delay 0.2 noselect
refclock PPS /dev/pps0 refid kPPS lock NMEA maxlockage 2 poll 4 precision 1e-7 prefer
```

**SOCK (NMEA)** - Coarse GPS time from gpsd via Unix domain socket. SOCK is used instead of gpsd's SHM (shared memory) interface. This does not avoid gpsd's [documented time-output stall](https://gitlab.com/gpsd/gpsd/-/issues/181), which affects both interfaces; see [Troubleshooting](docs/TROUBLESHOOTING.md#gpsd-dropping-time-output). On the tested Pi 5/MAX-M10S build, `chronyc sourcestats -v` showed a near-zero residual offset with `offset 0.000`, so that value stayed. Treat this as an empirical setting to verify on your own host, not a guaranteed default for all receivers and gpsd builds. `noselect` prevents chrony from syncing to this source directly - it exists solely to give PPS its second-of-day context.

**PPS /dev/pps0 (kPPS)** - PPS read directly from the kernel, independent of gpsd. `lock NMEA` ties the pulse to the NMEA source so chrony knows which second it belongs to. `maxlockage 2` limits how long PPS trusts stale NMEA data. `prefer` tells chrony to use this source when healthy.

Neither refclock depends on gpsd's SHM. PPS bypasses gpsd entirely.

Note: gpsd 3.25 may log `chrony_send` errors for `chrony.clk.ttyAMA0.sock`. On the tested build this was harmless noise from a secondary socket path that chrony was not using, while time still flowed through `chrony.ttyAMA0.sock`. Upstream gpsd docs are inconsistent here, so verify on your own host before assuming either socket name.

**Temperature compensation** is disabled and not recommended for stable indoor environments. Testing on the live Pi (12 hours of data, 8.8C range, quadratic fit) showed that enabling `tempcomp` degraded performance — chrony's own frequency tracking handles thermal drift better than explicit compensation when the environment is thermally stable. The correction noise from tempcomp exceeded the thermal drift it was compensating for.

The `scripts/collect_tempcomp_data.sh` and `scripts/tempcomp_gen.py` tools are retained for environments with significant temperature swings (e.g., outdoor enclosures, unheated spaces) where tempcomp may provide a net benefit.

See [`configs/chrony.conf`](configs/chrony.conf) for the full annotated config.

### 9. Start services

```bash
sudo systemctl restart chrony
sleep 2
sudo systemctl restart gpsd
```

### 10. Verify

Check that chrony sees all sources:

```bash
chronyc sources -v
```

Look for `#*` next to kPPS - the `*` means it's the selected source. NMEA should show `#?` (noselect). Network sources should show `^-` or `^?`.

Check overall sync status:

```bash
chronyc tracking
```

Key fields:
- **Reference ID**: Should show `kPPS`
- **Stratum**: Should be `1`
- **System time**: Offset from NTP time (nanoseconds = good)

PPS typically locks within 30 seconds of chrony starting if GPS has a fix. Cold starts may take 5-15 minutes.

### 11. Verify NMEA offset

Treat the SOCK offset as measured, not assumed. On the tested Pi 5/MAX-M10S build dated March 25, 2026, `chronyc sourcestats -v` showed `NMEA` `Offset -13ns` and `Std Dev 327ns` with `offset 0.000`, so no manual correction was needed.

Verify on your own host with:

```bash
chronyc sourcestats -v
```

If the NMEA source shows a stable non-zero offset over hours, tune the `offset` value empirically there. If it swings around wildly, the problem is elsewhere and not a simple offset correction.

### 12. Verify hardware timestamping

`hwtimestamp *` is only worth keeping if the NIC really supports it. Verify with:

```bash
sudo ethtool -T eth0
sudo chronyc ntpdata
```

On the tested Pi 5, `ethtool -T eth0` reported `hardware-transmit`, `hardware-receive`, and `hardware-raw-clock`, and `chronyc ntpdata` showed `TX timestamping : Hardware` and `RX timestamping : Hardware`.

## Network clients

Point other machines on your network at the Pi:

**chrony** (`/etc/chrony/chrony.conf`):
```
server <pi-ip-address> iburst
```

**systemd-timesyncd** (`/etc/systemd/timesyncd.conf`):
```
[Time]
NTP=<pi-ip-address>
```

Those clients will operate as stratum 2.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues including PPS signal problems, GPS fix failures, Bluetooth/UART conflicts, SHM stalling, and chrony source selection issues.

## References

- [Austin's Nerdy Things - Microsecond Accurate NTP with GPS PPS (2025)](https://austinsnerdythings.com/2025/02/14/revisiting-microsecond-accurate-ntp-for-raspberry-pi-with-gps-pps-in-2025/)
- [Tiago Freire - RPi Uputronics Stratum 1 Chrony](https://github.com/tiagofreire-pt/rpi_uputronics_stratum1_chrony)
- [GPSD Time Service HOWTO](https://gpsd.gitlab.io/gpsd/gpsd-time-service-howto.html)
- [chrony FAQ - Using PPS refclock](https://chrony-project.org/faq.html#using-pps-refclock)

## License

[MIT](LICENSE)
