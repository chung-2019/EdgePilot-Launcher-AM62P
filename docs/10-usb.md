# 10. USB

## What is attached

```bash
lsusb                  # one line per device
lsusb -t               # the hub/port tree, with drivers and speeds
```

`lsusb -t` is the more useful of the two: it shows *where* a device is attached
and which driver claimed it, which is what you need when a device enumerates but
does nothing.

If `lsusb` shows numbers instead of names, the image has no `usb.ids` database.
The numbers are the real information anyway:

```bash
for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    printf '%s  %s:%s  %s %s  %s Mbps\n' "$(basename $d)" \
        "$(cat $d/idVendor)" "$(cat $d/idProduct)" \
        "$(cat $d/manufacturer 2>/dev/null)" "$(cat $d/product 2>/dev/null)" \
        "$(cat $d/speed)"
done
```

## Did a driver bind?

Enumeration and binding are different steps, and a device can pass the first and
fail the second:

```bash
ls -l /sys/bus/usb/devices/1-1:1.0/driver     # the interface, not the device
dmesg | tail -20                              # right after plugging it in
```

`dmesg` immediately after plugging in is the highest-value command here. It shows
the enumeration, the speed, the descriptors, and either the driver binding or
what went wrong.

## Speed

```bash
cat /sys/bus/usb/devices/1-1/speed     # 480, 5000, 12, 1.5
```

A device that should be 480 and reports 12 usually means a cable or connector
problem — the high-speed pairs are not making it through. If it consistently
falls back, suspect the cable before the device.

## The dual-role port

The AM62P has USB ports that can be host or device. Which one a port is comes
from the device tree (`dr_mode = "host"`, `"peripheral"` or `"otg"`).

```bash
cat /sys/class/udc/*/state 2>/dev/null    # is the gadget side active?
```

A port in peripheral mode will not enumerate the flash drive you plug into it,
and there is no error to see — checking `dr_mode` in the live tree is quicker
than wondering.

## Power

```bash
cat /sys/bus/usb/devices/usb1/bMaxPower
```

A bus-powered hub with several devices behind it will brown out. The symptom is
a device that enumerates, works for a while, then disappears and comes back —
visible in `dmesg` as repeated disconnect/reconnect. Powered hub, or fewer
devices.

## USB serial adapters

```bash
ls -l /dev/ttyUSB* /dev/ttyACM*
ls -l /sys/bus/usb-serial/devices/
```

`/dev/ttyUSB*` comes from a bridge driver (ftdi_sio, cp210x, ch341, pl2303);
`/dev/ttyACM*` from the generic CDC-ACM class. Nothing appearing means the
specific bridge driver is not in the image — `dmesg` names the chip so you know
which one to add.

Node numbers are assignment order, not identity: unplug two adapters and plug
them back in the other order and they swap. For anything that has to be stable,
use a by-id path:

```bash
ls -l /dev/serial/by-id/
```

## USB storage

```bash
lsblk
mount /dev/sda1 /mnt
```

Missing `/dev/sd*` with the device visible in `lsusb` means `usb-storage` did not
bind, or the image lacks the filesystem driver. `dmesg` distinguishes the two,
and they need different fixes.

## Tools here

```bash
scripts/hardware_health_check.sh --host <address>
scripts/collect_logs.sh --host <address>        # includes the full USB state
```

The GUI's **USB** panel has the plain list, the tree, the sysfs detail view and a
serial-adapter view with driver bindings.

## Next

`11-gpio.md`
