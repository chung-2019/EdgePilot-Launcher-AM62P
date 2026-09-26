# 8. SPI

## There is nothing to scan

SPI has no addressing. A device is selected by a chip-select line, so there is no
equivalent of `i2cdetect`: nothing can be discovered, and a device exists only
because the device tree says it does and a driver bound to it.

This changes what troubleshooting means. On I2C you ask "does it answer?"; on SPI
you ask "did it get registered?".

```bash
ls /sys/class/spi_master/          # controllers
ls /sys/bus/spi/devices/           # registered devices
ls /dev/spidev*                    # user-space access nodes
```

An empty `/sys/bus/spi/devices/` is a device-tree statement, not a wiring
statement.

## Is the controller even enabled?

```bash
for n in /sys/firmware/devicetree/base/bus@*/spi@*; do
    echo "$(basename $n): $(tr -d '\0' < $n/status 2>/dev/null || echo okay)"
done
```

A controller with `status = "disabled"` enumerates nothing, whatever is wired to
it. Enabling it needs the same steps as any peripheral — including the pinctrl
group; see `06-device-tree.md`.

## Declaring a device

```dts
&main_spi0 {
    status = "okay";
    pinctrl-names = "default";
    pinctrl-0 = <&main_spi0_pins_default>;

    flash@0 {
        compatible = "jedec,spi-nor";
        reg = <0>;                          // chip select 0
        spi-max-frequency = <50000000>;
    };
};
```

| | |
|---|---|
| `reg` | the chip-select index, not an address |
| `spi-max-frequency` | per device; the controller uses the lowest it needs |
| `spi-cpol` / `spi-cpha` | clock mode, if the device is not mode 0 |

## Talking to a device from user space

Add a `spidev` child, or bind the driver to an existing node:

```dts
device@1 {
    compatible = "rohm,dh2228fv";   // a conventional stand-in for spidev
    reg = <1>;
    spi-max-frequency = <1000000>;
};
```

The kernel deliberately refuses to bind `spidev` to a bare `compatible =
"spidev"` — it logs `buggy DT: spidev listed directly in DT` and does nothing.
Use a real part's compatible string, or bind by hand:

```bash
echo spidev > /sys/bus/spi/devices/spi0.1/driver_override
echo spi0.1 > /sys/bus/spi/drivers/spidev/bind
```

Then:

```bash
spidev_test -D /dev/spidev0.1 -s 1000000 -p "\x9f\x00\x00\x00"
```

`spidev_test` comes with the kernel source under `tools/spi/`.

## What to check when a device does not appear

1. Is the controller enabled in the live tree?
2. Is the child node there, with the right `compatible`?
3. `dmesg | grep -i spi` — a probe failure usually says why.
4. Are the pins muxed to SPI, and does nothing else claim them?
5. Only then reach for a scope: clock present, chip select asserting, MISO
   moving.

Steps 1–4 are free and catch most of it.

## Chip-select gotchas

* `spi-cs-high` if the device wants an active-high select; without it the device
  sees nothing.
* Some controllers cannot hold CS across multiple messages
  (`SPI_CS_WORD` / `cs-change` semantics), which breaks devices that expect a
  continuous transaction.
* A CS line left floating (no pull-up, no pinmux) makes a device respond
  intermittently — the worst failure mode to debug from software.

## Tools here

```bash
scripts/hardware_health_check.sh --host <address>    # includes SPI enumeration
```

The GUI's **SPI** panel lists controllers, registered devices with their drivers,
spidev nodes, and separately what the device tree says — because the gap between
those two lists is the answer most of the time.

## Next

`09-uart.md`
