# Troubleshooting

## No PPS signal (`/dev/pps0` doesn't exist)

Check that the device tree overlay is loaded:

```bash
dmesg | grep pps
```

You should see something like `pps pps0: new PPS source`. If not:

1. Verify `/boot/firmware/config.txt` contains `dtoverlay=pps-gpio,gpiopin=18`
2. Verify the PPS wire is connected to **Pin 12** (GPIO 18) on the Pi header
3. Reboot after any config.txt changes

If `/dev/pps0` exists but `ppstest` shows no assertions:

```bash
sudo ppstest /dev/pps0
```

The GPS module may not have a satellite fix yet. PPS only fires once the module has a valid fix. Give it sky view and wait a few minutes.

## GPS has no fix

Check raw NMEA output:

```bash
cat /dev/ttyAMA0
```

If you see NMEA sentences (`$GNRMC`, `$GNGGA`, etc.) but the fix fields show `V` (void) or `0`, the module doesn't have enough satellites. Ensure the antenna has clear sky view. Cold starts can take 5-15 minutes.

If you see nothing at all:

1. Check wiring: GPS TX -> Pi Pin 10 (RX), GPS RX -> Pi Pin 8 (TX)
2. You must use raw mode to read serial: `stty -F /dev/ttyAMA0 <baud> raw -echo && cat /dev/ttyAMA0`
3. Verify baud rate matches module config: 9600 (factory default) or 115200 (after running configure_m10s.sh)
4. If using u-blox MAX-M10S, verify UBX protocol responds: `ubxtool -p MON-VER -f /dev/ttyAMA0 -s <baud> -P 34.10`
5. Ensure the serial console isn't grabbing the UART (see below)
6. Ensure gpsd is stopped before testing raw serial — gpsd holds the port exclusively

## Serial console conflict

The kernel will claim UART0 for console output by default, blocking gpsd. Remove the console parameter from the kernel command line:

Edit `/boot/firmware/cmdline.txt` and remove `console=serial0,115200` (or `console=ttyAMA0,115200`). Leave the `console=tty1` entry. Reboot.

## Bluetooth conflict

Raspberry Pi 3+ shares UART0 (`/dev/ttyAMA0`) with Bluetooth. You must move or disable Bluetooth:

**Option A** - Disable Bluetooth entirely:
```
dtoverlay=disable-bt
```

**Option B** - Move Bluetooth to the mini-UART (keeps BT functional but at reduced reliability):
```
dtoverlay=miniuart-bt
```

Add the chosen line to `/boot/firmware/config.txt` and reboot.

## chrony shows PPS but won't select it

Check `chronyc sources`:

```
#? NMEA    0   0   377     0   +176ms[ +176ms] +/- 1000us
#? kPPS    0   4     0     -     +0ns[   +0ns] +/-    0ns
```

If kPPS shows `Reach: 0`:

1. Verify gpsd is running: `systemctl status gpsd`
2. Verify PPS is firing: `sudo ppstest /dev/pps0`
3. Check that NMEA has reach - kPPS needs the NMEA source for its `lock` to work
4. Verify the SOCK file exists: `ls -la /run/chrony.ttyAMA0.sock`
5. If the socket file doesn't exist, restart chrony first (it creates the socket), then gpsd

If PPS has reach but shows `#?` instead of `#*`, chrony may still be evaluating the source. Wait 5-10 minutes after GPS acquires a fix.

## "Not synchronised" in chronyc tracking

This is normal at boot or when GPS is acquiring its first fix. Check:

```bash
chronyc tracking
cgps
```

If `cgps` shows a 3D fix but chrony still isn't synced after 10+ minutes, restart both services:

```bash
sudo systemctl restart chrony
sleep 2
sudo systemctl restart gpsd
```

## Permission denied on /dev/ttyAMA0

gpsd needs read/write access to the serial device. Either:

1. Run gpsd as root (default on Ubuntu)
2. Add the gpsd user to the `dialout` group: `sudo usermod -aG dialout gpsd`

Check permissions: `ls -la /dev/ttyAMA0` should show `crw-rw---- 1 root dialout`.

## gpsd dropping time output

gpsd can silently stop delivering time data to chrony on long-running instances. This has been observed in SHM setups and has also been reported in the field on SOCK-based setups. When it happens, `chronyc sources` shows NMEA and kPPS with `Reach: 0` and a stale `LastRx`, but `gpspipe` and `cgps` continue working - gpsd's client socket interface stays alive while its time output to chrony dies.

This behavior has been observed with the ATGM336H (AT6558-based) GPS module and may be related to how gpsd handles non-u-blox NMEA streams on long-running instances. Guides using u-blox modules (Austin's Nerdy Things, Tiago's Uputronics setup) do not report this issue. The upstream reports, however, come from u-blox users, and trace the stall to a corrupted serial read that sends gpsd into its autobaud hunt and a device reopen.

Related gpsd issues: [#150](https://gitlab.com/gpsd/gpsd/-/issues/150), [#177](https://gitlab.com/gpsd/gpsd/-/issues/177), [#181](https://gitlab.com/gpsd/gpsd/-/issues/181). Fixes landed in gpsd git head in August 2023, after the 3.25 release, so 3.25 and older are still affected. Ubuntu 24.04 ships 3.25; Ubuntu 26.04 ships 3.27.5, which has the fixes.

**Workaround:** A watchdog script monitors chrony's NMEA source and restarts gpsd when reach drops to 0. See [`scripts/gpsd-watchdog.sh`](../scripts/gpsd-watchdog.sh). Install it via cron to run every 5 minutes. This limits downtime to at most 5 minutes before auto-recovery.

**Hardware change:** The ATGM336H was replaced with a genuine u-blox module (Uputronics MAX-M10S), which gpsd is primarily developed and tested against, on March 24, 2026 — see [`scripts/configure_m10s.sh`](../scripts/configure_m10s.sh) for the module configuration. Because the upstream reports involve u-blox receivers too, keep the watchdog installed on gpsd 3.25 and older.

## Why SOCK instead of SHM

This setup uses SOCK (Unix domain socket) for NMEA instead of SHM, and reads PPS directly from the kernel. SOCK does not protect against the stall above, which hits SHM and SOCK alike. Reading PPS from the kernel keeps the pulse itself out of gpsd, but PPS is locked to NMEA for second numbering, so a stalled NMEA source takes kPPS down with it until gpsd is restarted.

As of March 25, 2026, the tested Pi 5 / Ubuntu 24.04 / gpsd 3.25 build used `/run/chrony.ttyAMA0.sock` successfully. Upstream gpsd documentation is inconsistent about whether serial timing should use `chrony.ttyAMA0.sock` or `chrony.clk.ttyAMA0.sock`, so verify the working path on your host with `chronyc sourcestats -v`, `journalctl -u gpsd`, and the contents of `/run`.

## Temperature compensation (tempcomp) makes things worse

If you enable `tempcomp` and notice degraded tracking (higher RMS offset, more jitter in sourcestats), disable it and compare. In thermally stable environments (indoor, climate-controlled, temperature swings under ~10C), chrony's built-in frequency tracking outperforms explicit temperature compensation.

**Why:** tempcomp adds discrete correction steps at each temperature reading. When the thermal drift is small, these corrections introduce more noise than the drift they're compensating for. Chrony's frequency estimator already adapts to slow thermal changes via the driftfile and its own tracking loop.

**Tested result:** On a Pi 5 in a climate-controlled house (8.8C CPU temp range over 12 hours), tempcomp was generated from 2,083 samples with a quadratic fit. Enabling it produced worse performance than running without it. Disabling tempcomp restored sub-200ns RMS offset and 0.005 ppm skew.

**When tempcomp helps:** Environments with rapid or large temperature swings (>15-20C) where chrony's tracking loop can't keep up — outdoor enclosures, unheated sheds, vehicles.

## chrony_send errors in gpsd log

```
gpsd:ERROR: NTP: chrony_send(10) Transport endpoint is not connected(107)
```

On the tested build, this was gpsd 3.25 trying to write to `/run/chrony.clk.ttyAMA0.sock` while chrony was using `/run/chrony.ttyAMA0.sock`. The errors were harmless because `chronyc sourcestats -v` still showed live NMEA samples and PPS stayed locked.

Do not assume that automatically on every build. If you see these log messages, confirm that chrony's NMEA source is still updating before ignoring them.
