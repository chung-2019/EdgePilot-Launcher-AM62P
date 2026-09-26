# 12. Bluetooth LE

## Is the controller there and up?

```bash
hciconfig -a                              # adapters
bluetoothctl show                         # BlueZ's view
systemctl status bluetooth
```

Two harmless-looking things to know immediately:

**`hciconfig` reports `Read_Local_Name` I/O error** on an LE-only controller.
That is a Classic Bluetooth command; an LE-only part answers with an error. LE
scanning and GATT are unaffected. Filter it out and move on.

**`btmgmt` fails with `Busy`.** It wants the management socket, which
`bluetoothd` already holds. Either stop bluetoothd (and lose everything that
depends on it) or use `bluetoothctl`. Every tool here uses `bluetoothctl`.

## Scanning

```bash
bluetoothctl
[bluetooth]# power on
[bluetooth]# scan on
...
[bluetooth]# scan off
[bluetooth]# devices
```

Scripted:

```bash
{ echo 'power on'; sleep 1; echo 'scan on'; sleep 10;
  echo 'scan off'; echo 'devices'; sleep 1; echo 'quit'; } | bluetoothctl
```

Or use `examples/ble-scan/ble_scan.py`, which sorts by signal strength and
handles the two parsing traps below.

### Trap one: carriage returns

`bluetoothctl` redraws its prompt with a bare CR, not a newline. Split its output
on LF only and events get concatenated or hidden behind the prompt. Split on
both.

### Trap two: property lines look like names

```
[NEW] Device AA:BB:CC:DD:EE:01 Thermometer 1
[CHG] Device AA:BB:CC:DD:EE:01 Connected: yes
```

Same shape, different meaning. Distinguish by a known property keyword followed
by a colon (or by `is`). Get it wrong and your device list fills with entries
named `RSSI: -60`. Get it too aggressive and you throw away real names like
`Class A Sensor`.

## Pairing with numeric comparison

The association model depends on what both sides claim they can do. To get
numeric comparison — the "do these numbers match?" flow — the local agent has to
advertise a display and a keyboard:

```bash
bluetoothctl
[bluetooth]# agent KeyboardDisplay
[bluetooth]# default-agent
[bluetooth]# pair AA:BB:CC:DD:EE:01
Confirm passkey 123456 (yes/no): yes
[bluetooth]# trust AA:BB:CC:DD:EE:01
```

**The one rule that matters:** while that passkey prompt is pending, BlueZ has
the agent busy. Any other command sent into the session gets refused by the agent
and the pairing dies with an authentication failure. Answer `yes` or `no` first,
then do anything else.

This is why the GUI's BLE Console blocks every other button while a prompt is
outstanding — the failure is otherwise baffling, because the command you sent
looks unrelated to the pairing that broke.

## GATT

```bash
[bluetooth]# connect AA:BB:CC:DD:EE:01
[bluetooth]# menu gatt
[bluetooth]# list-attributes
[bluetooth]# select-attribute 00002a1c-0000-1000-8000-00805f9b34fb
[bluetooth]# read
[bluetooth]# notify on
[bluetooth]# back
```

`ServicesResolved: yes` is the signal that the attribute table is usable.
Selecting an attribute before that fails or returns nothing.

`notify on` is what you want for a sensor that pushes readings; `read` gives you
one value now.

## Decoding a value

For the standard Health Thermometer characteristic (`2A1C`):

```
flags (1 byte) | mantissa (24-bit signed, LE) | exponent (int8) | ...
value = mantissa * 10^exponent
```

Two sanity gates are worth applying before believing a decode, because *any*
five-byte notification will produce a number:

* the top four bits of the flags byte are reserved; if any are set, this is not
  an HTS frame
* an all-zero mantissa is a placeholder, not a reading

Without those gates a vendor-specific notification decodes into something that
looks like a plausible temperature, and a wrong number is worse than an error.
`gui/am62p_workbench/remote/ble.py::parse_temperature()` implements this, with
tests.

## Clearing state

```bash
[bluetooth]# disconnect AA:BB:CC:DD:EE:01
[bluetooth]# remove AA:BB:CC:DD:EE:01     # removes the bond
```

`remove` matters when re-pairing fails for no visible reason: both sides keep
keys, and a stale bond on one side gives an authentication failure that looks
like a hardware problem.

## Capturing the protocol

```bash
btmon -w /tmp/trace.snoop        # write raw, read it later with Wireshark
```

Prefer `-w` over live decoding: in a busy RF environment `btmon`'s own decoder
can be overwhelmed, and losing the capture to a crash in the capture tool is a
waste of a reproduction.

## The failure that arrives hours later

On a combo Wi-Fi/Bluetooth part the two radios share firmware. A Wi-Fi firmware
recovery can take the Bluetooth side down with it — the adapter simply
disappears, long after boot, with nothing obvious in the log.

```bash
hciconfig -a                     # nothing at all now
dmesg | grep -iE "firmware|recovery|hci"
```

Recovering usually means restarting the Bluetooth enablement path rather than
rebooting; the exact units depend on the image.
See `troubleshooting/ble-decision-tree.md`.

## Tools here

```bash
scripts/hardware_health_check.sh --host <address> --only bluetooth
```

The GUI has **BLE Scan** for discovery and **BLE Console** for pairing and GATT
work, where each step depends on the last.

## Next

`13-display-touch.md`
