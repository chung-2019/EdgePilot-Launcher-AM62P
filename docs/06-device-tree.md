# 6. Device tree

The device tree is how the kernel learns what hardware exists. On an SoC with
far more peripherals than pins, most of them are disabled, and enabling one is a
device-tree change rather than a driver change.

## The two views, and why you need both

**Source** — what you can edit:

```
$SDK/board-support/ti-linux-kernel-*/arch/arm64/boot/dts/ti/
    k3-am62p5-sk.dts        the board
    k3-am62p.dtsi           the SoC
    k3-am62p-main.dtsi      the peripherals
```

**Live** — what the kernel actually booted with:

```bash
dtc -I fs -O dts /proc/device-tree | less
```

They differ whenever an overlay is applied, and the difference is exactly what
you want to see. Search both:

```bash
# GUI: Device Tree panel, one keyword, both views
# or by hand:
grep -rn "tmp119" $SDK/board-support/ti-linux-kernel-*/arch/arm64/boot/dts/ti/
ssh root@board 'dtc -I fs -O dts /proc/device-tree' | grep -A20 tmp119
```

## Reading a node

```dts
&main_i2c2 {
    status = "okay";
    pinctrl-names = "default";
    pinctrl-0 = <&main_i2c2_pins_default>;
    clock-frequency = <100000>;

    i2c-mux@71 {
        compatible = "nxp,pca9543";
        reg = <0x71>;
        #address-cells = <1>;
        #size-cells = <0>;

        i2c@0 {
            reg = <0>;
            temperature-sensor@48 {
                compatible = "ti,tmp117";
                reg = <0x48>;
            };
        };
    };
};
```

| | |
|---|---|
| `&main_i2c2` | extends a node defined elsewhere by its label |
| `status = "okay"` | enable it; `"disabled"` means the driver never probes |
| `compatible` | how a driver claims the node — the single most important line |
| `reg` | the address on the parent bus |
| `pinctrl-0` | which pin configuration to apply |

`compatible` is where most "the driver does not load" problems live. It has to
match a string the driver declares, exactly.

## Overlays

An overlay is a fragment applied on top of the base tree, which means board
variants do not need a forked .dts.

```dts
/dts-v1/;
/plugin/;

&main_i2c2 {
    status = "okay";

    i2c-mux@71 {
        compatible = "nxp,pca9543";
        reg = <0x71>;
        #address-cells = <1>;
        #size-cells = <0>;

        i2c@0 {
            reg = <0>;
            temperature-sensor@48 {
                compatible = "ti,tmp117";
                reg = <0x48>;
            };
        };
    };
};
```

Build it:

```bash
dtc -@ -I dts -O dtb -o my-overlay.dtbo my-overlay.dtso
```

`-@` is required — it emits the symbol table that lets the overlay reference
labels like `&main_i2c2`. Without it, applying the overlay fails with an
unhelpful message about missing symbols.

Install and enable it:

```bash
scp -O my-overlay.dtbo root@board:/run/media/boot-mmcblk1p1/overlays/
ssh root@board
vi /run/media/boot-mmcblk1p1/uEnv.txt
# name_overlays=ti/my-overlay.dtbo
reboot
```

## Did my overlay load?

There is no list to query. U-Boot applies overlays before Linux starts, so the
kernel has no record of them.

The two answers that do exist:

```bash
# what the bootloader was asked to apply
cat /run/media/boot-mmcblk1p1/uEnv.txt | grep overlays

# whether the nodes it should have added are actually there
dtc -I fs -O dts /proc/device-tree | grep -A10 tmp117
```

The second is the real test. The GUI's Device Tree panel has an Overlays button
that runs both and says the same thing.

## What "enabling a peripheral" involves

Rarely just `status = "okay"`. Usually:

1. The controller node: `status = "okay"`.
2. A pinctrl group, and a reference to it. The pins have several functions and
   something else may already own them.
3. Child nodes for the devices on the bus, with correct `compatible` and `reg`.
4. Sometimes a clock or regulator reference.

Miss step 2 and the controller registers, enumerates nothing, and reports no
error — a peripheral that is "not there" with the driver loaded is almost always
a pinmux problem.

## Checking the result

```bash
ls /proc/device-tree/                       # top-level nodes
ls /sys/bus/i2c/devices/                    # what registered
dmesg | grep -i "i2c\|probe\|failed"        # what the driver said
```

A node in the device tree with nothing under `/sys/bus/*/devices/` means no
driver claimed it: check `compatible`, and check the driver is built in or
loadable.

## Related

* `troubleshooting/i2c-decision-tree.md`
* `docs/07-i2c.md`
* The GUI's Device Tree panel prints the enclosing node with its ancestors, so
  the output reads like source rather than a grep hit.

## Next

`07-i2c.md`
