# 13. Display and touch

## The pipeline

```
tidss (DRM driver) -> encoder (OLDI / DPI / HDMI bridge) -> panel -> your eyes
                                        ^
                       compositor (Weston) holds DRM master
                                        ^
                            your application, over Wayland
```

Each arrow is a place it can break, and the symptom is the same at every one: a
black screen. Working along the chain beats guessing.

## Is the panel detected?

```bash
for d in /sys/class/drm/card*-*; do
    echo "$(basename $d): status=$(cat $d/status) enabled=$(cat $d/enabled) \
dpms=$(cat $d/dpms) mode=$(head -1 $d/modes)"
done
```

```
card0-LVDS-1: status=connected enabled=enabled dpms=On mode=1920x1200
```

| Field | What it tells you |
|---|---|
| `status` | is a panel detected — `connected`, `disconnected`, `unknown` |
| `enabled` | has a CRTC been assigned to it |
| `dpms` | is it powered |
| `modes` | what timings the driver believes in |

The combinations that matter:

* `disconnected` on a panel that is definitely wired: a fixed panel usually has
  no detect pin, so the driver reports `connected` only because the device tree
  says a panel is there. `disconnected` therefore means the device tree is wrong,
  not the cable.
* `connected` but `enabled=disabled`: nothing is driving it — no compositor, or
  one that failed to pick a mode.
* everything right and still black: backlight, or the compositor drawing nothing.

## The full resource dump

```bash
modetest -M tidss -c
```

Expect it to fail with a permission or busy error while a compositor is running —
that is not a display fault, it is DRM master working as designed. Stop the
compositor if you really need `modetest`, or use the sysfs view above.

## Backlight

```bash
ls /sys/class/backlight/
```

**Empty is a legitimate answer.** On many panels the brightness is controlled by
the add-on board or a fixed resistor, and no amount of software will change it.
Before hunting for a driver, check whether the signal even reaches the SoC:

```bash
find /proc/device-tree -iname '*backlight*'
grep -rl pwm-backlight /proc/device-tree
ls /sys/class/pwm/
```

All three empty means the device tree defines no backlight, and the hardware
probably has none to define. Record it in the board profile so nobody re-checks:

```yaml
display:
  backlight_expected: false
```

## Kernel messages

```bash
dmesg | grep -iE 'tidss|oldi|panel|drm|dss'
```

The useful lines here are the mode the driver chose and any complaint about
timings, links or bandwidth.

## Touch

```bash
cat /proc/bus/input/devices        # every input device with its handlers
ls -l /dev/input/
evtest /dev/input/event0           # live events; does not grab the device
```

`evtest` shows `ABS_MT_POSITION_X/Y` and `BTN_TOUCH` as you touch. It does not
grab the device, so a running application keeps receiving touches while you
watch.

For an I2C touch controller, the health check is the `i2cdetect` cell plus sysfs:

```bash
i2cdetect -y -r 0                                  # look at the address
ls -l /sys/bus/i2c/devices/0-0041/driver           # did a driver bind?
cat /sys/bus/i2c/devices/0-0041/input/input*/name  # did it register an input?
```

Three states, three different problems:

| Scan cell | Meaning | What to fix |
|---|---|---|
| `UU` | a driver owns it — healthy | nothing |
| a number | the chip answers, no driver bound | device tree `compatible`, or the driver |
| `--` | nothing answers | power, the reset GPIO, wiring |

```bash
scripts/hardware_health_check.sh --host <address> --only touch
```

## Touch works in evtest but not in the application

Now it is a Wayland or Qt question, not a kernel one:

* Does the compositor see the device? `journalctl -u weston | grep -i input`
* Is the application on Wayland at all? `QT_QPA_PLATFORM=wayland`, and
  `QT_LOGGING_RULES='qt.qpa.*=true'` to see what it picked.
* Are the axes swapped or inverted? That is a calibration matter — a
  `libinput calibration matrix` property on the device, or a transform in the
  compositor's configuration.

## Rotation

Rotating the panel is a compositor setting, not an application one. In
`weston.ini`:

```ini
[output]
name=LVDS-1
transform=270
```

Rotating in the application instead leaves touch coordinates unrotated, which is
worse than not rotating at all.

## Related

* `troubleshooting/display-decision-tree.md` — black screen, step by step
* `docs/14-systemd.md` — why a kiosk must wait for the Wayland socket

## Next

`14-systemd.md`
