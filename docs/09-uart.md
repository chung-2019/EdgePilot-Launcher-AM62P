# 9. UART and serial

Three different things get called "the serial port" on a board like this:

| | |
|---|---|
| the **console** | where boot messages and the login prompt go |
| an on-SoC **UART** | wired to a header or an on-board peripheral |
| a **USB serial adapter** | appears as `/dev/ttyUSB*` or `/dev/ttyACM*` |

Only the first is set up for you.

## The console

115200 8N1, no flow control. Hardware flow control left on in the terminal is
the usual reason the console shows output but accepts no input.

It is the console because the kernel command line says so:

```bash
cat /proc/cmdline        # console=ttyS2,115200n8 ...
```

Do not use that port for anything else while it is the console — getty owns it,
and two readers on one tty produces missing bytes rather than an error.

## What ports exist

```bash
ls -l /dev/ttyS* /dev/ttyUSB* /dev/ttyACM*
grep -E 'serial|usb' /proc/tty/drivers
dmesg | grep -i tty
```

For a USB adapter, the useful question is whether a driver bound:

```bash
ls -l /sys/bus/usb-serial/devices/
```

Nothing there means the driver for that bridge chip is missing from the image —
common for the less usual bridges. `dmesg` right after plugging it in names the
chip.

## Configure a port

```bash
stty -F /dev/ttyUSB0 115200 raw -echo cs8 -cstopb -parenb min 0 time 0
stty -F /dev/ttyUSB0 -a          # read back what it actually is
```

| | |
|---|---|
| `raw` | no line discipline: no CR/LF translation, no editing |
| `-echo` | do not echo received bytes back out — otherwise you talk to yourself |
| `cs8 -cstopb -parenb` | 8N1 |
| `min 0 time 0` | non-blocking reads |

Skipping `raw` is why a binary protocol "mostly works": the line discipline
rewrites `0x0D`/`0x0A` and eats `0x11`/`0x13` as flow control.

## Talk to a device

```bash
# receive
cat /dev/ttyUSB0 | xxd

# send hex
printf '\x51\xC0\x00\x00' > /dev/ttyUSB0
```

For anything that needs a request and a timed reply, use the example — timing
matters and shell redirection has none:

```bash
scp -O examples/../gui/am62p_workbench/scripts/serial_probe.py root@board:/tmp/
ssh root@board 'python3 /tmp/serial_probe.py /dev/ttyUSB0 115200 "01 02 03" 8 1000 1 1000'
```

Arguments: device, baud, request bytes (or `-` to listen only), expected reply
length (0 = whatever arrives), timeout ms, repetitions (0 = forever), interval
ms. It prints the bytes, their ASCII rendering and the arithmetic checksum of
all but the last byte as a hint. It does not decode any protocol — that part is
yours.

The GUI's **Serial** panel is the same probe with a form in front of it.

## Enabling another on-SoC UART

Device-tree work, like any peripheral:

```dts
&main_uart5 {
    status = "okay";
    pinctrl-names = "default";
    pinctrl-0 = <&main_uart5_pins_default>;
};
```

Then check it appeared:

```bash
dmesg | grep -i "ttyS\|uart"
ls /dev/ttyS*
```

A UART that stays silent with the node enabled is usually a pinmux conflict —
another node claiming the same pins wins, quietly. `06-device-tree.md` covers
that.

## Levels

An SoC UART is 3.3 V logic. It is not RS-232 (±12 V) and it is not RS-485
(differential). Wiring a 3.3 V UART straight to an RS-232 device damages the SoC
pin; a transceiver is not optional. And TX goes to RX — crossed, not straight.

## Symptoms and causes

| Symptom | Usual cause |
|---|---|
| nothing at all | wrong device node, or the port is the console and getty owns it |
| garbage | wrong baud, or a level mismatch |
| every byte doubled | `-echo` missing, or the device echoes |
| first request ignored, later ones fine | the adapter's DTR/RTS reset the device on open — wait ~400 ms after opening |
| bytes missing under load | no flow control, and the receiver's FIFO overruns |
| works as root, not as a user | the account is not in the `dialout` group |

## Related

* `gui/am62p_workbench/scripts/serial_probe.py`
* `docs/10-usb.md` — for the adapter side

## Next

`10-usb.md`
