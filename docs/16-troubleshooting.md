# 16. Troubleshooting reference

Findings from real bring-up, arranged by subsystem. Most of these look like
faults and are not, or look like one fault and are another.

For a symptom you are looking at right now, start with the decision trees --
they ask questions in an order that narrows things down:

| Symptom | Tree |
|---|---|
| a device does not answer on I2C | `../troubleshooting/i2c-decision-tree.md` |
| black screen, or the app is not on screen | `../troubleshooting/display-decision-tree.md` |
| BLE scan, pairing or GATT problems | `../troubleshooting/ble-decision-tree.md` |
| Wi-Fi will not connect, or drops | `../troubleshooting/wifi-decision-tree.md` |
| the board does not boot, or stops partway | `../troubleshooting/boot-decision-tree.md` |

Or collect everything at once and read it afterwards:

```bash
scripts/hardware_health_check.sh --host <address>
scripts/collect_logs.sh --host <address>
```

## SSH

**`BatchMode` fails immediately instead of asking for a password.** By design.
Every panel except **Password SSH** uses key authentication, so a missing key is
an instant, obvious failure rather than a GUI hanging on a prompt it cannot
answer. Deploy a key, or use the password panel.

**`systemctl is-active sshd` says `inactive` but SSH works.** The server is
socket-activated: systemd listens, and spawns a server process per connection.
`inactive` between connections is the normal state, not an outage.

**Password login fails and there is no `sshd_config`.** The board is probably
running dropbear rather than OpenSSH. There is no config file at all — the
password policy is in the command-line flags of the running process:

| Flag | Effect |
|---|---|
| `-s` | Disable password logins entirely |
| `-g` | Disable password login for root |
| `-w` | Disallow root login |
| `-B` | Allow blank passwords |

`ps aux | grep dropbear` shows them; `/etc/default/dropbear` may add more. If
none of `-s`, `-g`, `-w` are present, root password login is enabled and a
failure means the password is simply wrong. The **Password SSH → SSH server**
button reports all of this.

## I2C

**`i2cdetect` shows `UU`.** Not an error: a kernel driver has claimed that
address, which is what you want for a device that has a driver. It also means
you cannot talk to it with `i2cget`/`i2cset` — the transfer will return EBUSY.

**A muxed sensor is on a bus number that keeps changing.** It will. When a mux
driver binds, the kernel creates one child adapter per channel and numbers them
in whatever order it enumerates. Adding an overlay, changing the kernel or
enabling another bus renumbers them. Resolve the child from the symlink:

```
/sys/bus/i2c/devices/<bus>-<addr>/channel-<n> -> ../i2c-<child>
```

The I2C panel does this on every read, which is why it works across kernel
changes that break a hard-coded bus number.

**The mux responds but nothing downstream does.** Two common causes, in this
order: no channel is enabled (a mux with no driver powers up with all channels
disabled — nothing downstream is reachable until you write the control
register), or the sensor really is not there. The identity check separates them:
a wrong or absent device ID means the address is not what the profile claims.

**A bus scan hangs.** A device that NAKs mid-transfer can wedge the probe. Scans
are bounded at 18 s and say so. Scan a parent bus, or read the sensor directly.

## Bluetooth

**`btmgmt` says "Busy".** `bluetoothd` owns the management socket. Use
`bluetoothctl`, which is what both BLE panels do.

**`hciconfig` reports a `Read_Local_Name` I/O error.** Expected on an LE-only
controller: that is a Classic command. LE scanning and GATT are unaffected.

**Pairing aborts with an authentication failure right after the passkey
appears.** While a numeric-comparison prompt is pending, BlueZ has the agent
busy; any other command sent into the session gets refused by the agent, and the
pairing dies. The BLE console blocks everything except `yes` and `no` while a
prompt is outstanding, for exactly this reason.

**A characteristic value decodes to a plausible but wrong temperature.** Length
alone does not identify a Health Thermometer frame. The decoder refuses frames
with reserved flag bits set or an all-zero mantissa, and reports raw bytes
instead — a wrong number is worse than no number.

## Wi-Fi

**`cc33xx-nvs.bin ... error -2`.** The calibration blob is missing from some SDK
releases. The driver falls back to defaults, including a default MAC, and basic
connectivity works -- so if `wlan0` exists this is not the fault you are chasing.
Worth fixing before shipping; not worth an afternoon during bring-up.

**A 5 GHz AP is invisible to the board but obvious to a phone.** Regulatory
domain. `iw reg get` returning `country 00: DFS-UNSET` is the world-roaming
default, and it hides channels.

**`iw reg set` appears to do nothing.** `regulatory.db` is missing from
`/lib/firmware/`, and the setting is being ignored silently.

**`iw dev wlan0 scan` says `Device or resource busy`.** A supplicant owns the
interface. Normal -- ask it instead: `wpa_cli -i wlan0 scan_results`.

**Wi-Fi looks fine because `ping` succeeds.** Bind the test to the interface. A
board with Ethernet up answers an unbound ping over Ethernet:
`ping -I wlan0 -c 4 www.example.com`.

**Two default routes.** With Ethernet and Wi-Fi both up, the metric decides which
one carries traffic, and it is usually not the one you are testing.

**The Bluetooth adapter disappeared hours after boot.** On a combo part, a Wi-Fi
firmware recovery takes the BLE side with it. Look in the Wi-Fi log for a
recovery at the same timestamp -- the Bluetooth log will not mention it.

## Display

**`/sys/class/backlight` is empty.** On many panels the brightness is controlled
by the display add-on board, not by the SoC, and no amount of software will
change it. Set `display.backlight_expected: false` in the profile and the check
reports this as expected rather than as a fault.

**`modetest` fails with a permission or busy error.** A running compositor holds
DRM master. Normal — use the sysfs connector view instead.

## Application startup

A kiosk application that does not appear has three causes needing three
different fixes. The **App & Compositor** panel names which one you have:

| Case | Symptom | Fix |
|---|---|---|
| A | Compositor not up, no Wayland socket; the app waits forever in its pre-start | Restart the compositor. Restarting the app achieves nothing. |
| B-1 | Compositor fine, app stopped or disabled — usually left that way after debugging | Enable and start the app |
| B-2 | Compositor fine, app crashes repeatedly until systemd gives up (`start-limit-hit`) | `reset-failed`, start, then read the journal for the actual crash |

Distinguishing A from B is the whole point: they look identical on screen (a
black display) and have opposite fixes.

## Boot

**The screen is black for several seconds after power-on.** Four independent
stages can cause it — bootloader splash, kernel logo, psplash, the application.
The Boot panel walks them in order and reports what each is doing.

**The bootloader splash does not appear.** Two usual causes: the wrong colour
depth (U-Boot wants 32-bit BGRA) and a compressed size the bootloader will not
decompress. Neither produces an error message — the screen is simply blank. The
Build & Test splash recipe checks both.

**Overlays: is mine loaded?** Linux keeps no list of overlays applied by U-Boot,
so there is nothing to query. The two real answers are the bootloader variable
that requested it, and the presence of a node the overlay was meant to add —
search the live tree in the Device Tree panel.

## Build and deploy

**The first build after installing the SDK fails with EACCES.** The installer
runs as root, so its output is root-owned. The SDK Setup panel detects the
build account and hands it the example-applications tree afterwards; if you
installed by hand, `chown -R` it yourself.

**A build produced a host binary instead of a target one.** The SDK environment
was not sourced. Deploy → **Check artefact** runs `file` on the result, which
catches this before it reaches the board.

## Remote UI

**Two application instances fight over hardware.** They will, for anything
exclusive. Kernel-mediated resources (I2C, sysfs) are serialised and both
instances read them fine. A serial port opened by one is unavailable to the
other, and two processes driving one Bluetooth adapter will interfere with each
other's pairing and notifications. Keep the remote instance on read-only
screens.

**The remote instance is not a mirror of the panel.** It is a second instance
with its own state. There is no supported way to mirror the real framebuffer
without compositor support for remoting.

## Related

* `../troubleshooting/` -- decision trees for a symptom in front of you
* `scripts/hardware_health_check.sh` -- all of these checks in one pass
* `scripts/collect_logs.sh` -- a bundle to read later or attach to a report
