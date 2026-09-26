# 4. First boot

Getting from a box to a login prompt, and knowing which of the four boot stages
you are looking at when the screen is black.

## Write an image

The SDK ships one under `filesystem/`, usually `tisdk-default-image-*.wic.xz`.

```bash
# Linux / WSL: identify the card first, then write to the *disk*, not a partition
lsblk
xzcat tisdk-default-image-am62pxx-evm.wic.xz | sudo dd of=/dev/sdX bs=4M status=progress
sync
```

On Windows, balenaEtcher or Raspberry Pi Imager (custom image) handle `.wic.xz`
directly. Under WSL you cannot write to a physical SD card without extra
plumbing — use a Windows tool.

Set the boot switches for SD boot; the silkscreen or the board's user guide has
the pattern.

## The serial console

Get this working before anything else. It is the only view of the boot that
survives a broken display, a missing network and a wrong device tree.

Connect the USB-C UART port. Several ttys appear; the main console is usually
the first:

```bash
# Linux / WSL (needs usbipd-win to attach the device to WSL)
picocom -b 115200 /dev/ttyUSB0

# Windows
# PuTTY or Tera Term, 115200 8N1, no flow control
```

The one thing worth remembering: **115200 8N1, no flow control**. Hardware flow
control on by default in the terminal is why the console sometimes accepts no
input.

## The four boot stages

Power on, and in order:

| Stage | What you see | Where it comes from |
|---|---|---|
| 1 | bootloader splash (a BMP) | U-Boot, from the FAT partition |
| 2 | penguins, one per CPU core | the kernel's fbcon logo |
| 3 | a vendor splash with a progress bar | psplash, started by systemd |
| 4 | your application | your kiosk unit |

A black screen is one of these four not happening, and they have nothing to do
with each other. Walk them in order rather than guessing:

```bash
scripts/hardware_health_check.sh --host <address>
# or the GUI's Boot panel, which reports each stage separately
```

Stage 2 is suppressed by `logo.nologo` in the kernel command line; stage 3 by
masking the psplash units. Many production images do both, so a black gap
between stages 1 and 4 can be entirely intentional.

## Log in

Serial console, user `root`, no password on a stock TI image. Then find the
address:

```bash
ip -br addr
```

Set a password before putting the board on any shared network:

```bash
passwd
```

## Get onto the network

DHCP is on by default for the wired interface. If you need a fixed address, the
image uses either systemd-networkd or connman depending on the build:

```bash
# systemd-networkd
cat > /etc/systemd/network/10-eth0.network <<'EOF'
[Match]
Name=eth0

[Network]
Address=192.168.0.42/24
Gateway=192.168.0.1
DNS=192.168.0.1
EOF
systemctl restart systemd-networkd

# connman
connmanctl config ethernet_<mac>_cable --ipv4 manual 192.168.0.42 255.255.255.0 192.168.0.1
```

A DHCP address will move eventually, which is why every tool here takes the
address as an argument and the board profile only supplies a default.

## Set the clock

```bash
date -u
```

If it says 1970, the board has no RTC battery or it is flat. That breaks build
timestamps, journal ordering and anything using TLS, in ways that are hard to
attribute later.

```bash
scripts/setup_evm.sh --host <address> --set-time
```

## Then run the setup script

```bash
scripts/setup_evm.sh --host <address> --deploy-key
```

It deploys an ssh key, checks the architecture against the board profile,
compares the clock, inventories the diagnostic tools and warns about a full or
read-only root filesystem. Run it again later without `--deploy-key` as a health
check.

## Things that look broken and are not

**`i2cdetect` shows `UU`.** A driver has claimed that address. Correct.

**`systemctl is-active sshd` says `inactive`.** Socket-activated: systemd
listens and spawns a server per connection.

**`/sys/class/backlight` is empty.** On many panels the brightness is not wired
to the SoC at all.

**modetest fails with a busy or permission error.** A compositor holds DRM
master.

## Next

`05-network-and-ssh.md`
