# 11. GPIO

## Use the character device, not sysfs

The `/sys/class/gpio` interface is deprecated and removed from newer kernels. It
also had a real design problem: nothing owned a pin, so two programs could drive
the same line and neither would know.

The character device (`/dev/gpiochip*`) fixes that with proper handles, and comes
with tools:

```bash
gpiodetect                     # controllers and how many lines each has
gpioinfo                       # every line: name, consumer, direction, state
gpioget gpiochip1 20           # read one line
gpioset gpiochip1 20=1         # drive one line
gpiomon gpiochip1 20           # watch for edges
```

If `gpiod` tools are not in the image, add `libgpiod-tools`; they are small.

## Reading gpioinfo

```
gpiochip1 - 32 lines:
    line   0:  unnamed  unused   input   active-high
    line  20:  "led-red" "heartbeat" output active-low [used]
    line  21:  unnamed  "regulator-3v3" output active-high [used]
```

`[used]` with a consumer name means a driver holds that line — a regulator, an
LED class device, a reset line. **Do not drive it from user space.** The driver
will fight you, and the resulting behaviour looks like flaky hardware.

That single column answers the most common GPIO question: "why does my `gpioset`
have no effect?"

## Numbering

Line numbers are per chip and come from the SoC's banks. A schematic saying
`GPIO1_20` maps to line 20 on the chip that is bank 1 — but which `gpiochipN` is
bank 1 is assignment order, not a fixed number.

```bash
gpiodetect
# gpiochip0 [42110000.gpio] (32 lines)
# gpiochip1 [600000.gpio] (87 lines)
```

Match the base address against the device tree rather than assuming the index:

```bash
grep -rn "600000" $SDK/board-support/ti-linux-kernel-*/arch/arm64/boot/dts/ti/k3-am62p*.dtsi
```

## Naming lines in the device tree

Worth doing once so nobody has to count again:

```dts
&main_gpio1 {
    gpio-line-names =
        "", "", "", "", "", "", "", "",          /* 0-7 */
        "", "", "", "", "", "", "", "",          /* 8-15 */
        "", "", "", "", "sensor-reset", "", "", "";  /* 16-23 */
};
```

Then:

```bash
gpiofind sensor-reset          # gpiochip1 20
gpioset $(gpiofind sensor-reset)=1
```

## Setting a pin at boot, and keeping it set

A `gpioset` from a shell releases the line when the process exits, and most
drivers return the pin to its default. Two ways to make a state persist:

**A gpio-hog in the device tree** — the right answer for something that must be
in a fixed state from boot:

```dts
&main_gpio1 {
    sensor-reset-hog {
        gpio-hog;
        gpios = <20 GPIO_ACTIVE_HIGH>;
        output-high;
        line-name = "sensor-reset";
    };
};
```

**A systemd service** — for something that needs sequencing or logic. Keep the
process alive (`gpioset ... && sleep infinity`, or `Type=oneshot` with
`RemainAfterExit=yes` only if the driver keeps the state), or the line reverts
the moment it exits. A one-shot `gpioset` in a unit that exits is a common way to
"set" a pin that immediately un-sets itself.

## Pinmux comes first

A pin can only be a GPIO if the pinmux says so. If the pin is muxed to a UART or
an I2C function, GPIO access either fails or does nothing:

```dts
&main_pmx0 {
    my_gpio_pins_default: my-gpio-pins-default {
        pinctrl-single,pins = <
            AM62PX_IOPAD(0x01b0, PIN_OUTPUT, 7)   /* mode 7 = GPIO */
        >;
    };
};
```

Mode 7 is GPIO on this family. A pin that reads as the wrong level regardless of
what you write is usually still muxed to its default function.

## Interrupts and edges

```bash
gpiomon --num-events=5 gpiochip1 20
```

`gpiomon` needs the line to be interrupt-capable — not all are. When a line
cannot generate interrupts the only option is polling, which is a hardware fact
rather than a software choice.

## Symptoms and causes

| Symptom | Cause |
|---|---|
| `gpioset` has no effect | the line is `[used]` by a driver, or muxed to another function |
| the state reverts immediately | the process that set it exited |
| `Device or resource busy` | another process holds the handle |
| the level is inverted | `active-low` in the line's flags, or the schematic inverts it |
| `gpiomon` says the line is not interrupt-capable | it is not; poll instead |

## Related

* `docs/06-device-tree.md` — pinctrl and hogs
* `docs/14-systemd.md` — keeping a line asserted across boots

## Next

`12-ble.md`
