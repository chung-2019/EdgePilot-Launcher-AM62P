# Development Documentation

These documents are part of the public project source and should be included
when the repository is submitted to GitHub. They describe the reproducible
host setup, AM62P toolchain, EVM preparation, hardware interfaces, and
deployment workflow.

## Setup and Build

1. [WSL installation](01-wsl-installation.md)
2. [TI SDK installation](02-ti-sdk-installation.md)
3. [Cross-compilation](03-cross-compilation.md)
4. [EVM first boot](04-evm-first-boot.md)
5. [Network and SSH](05-network-and-ssh.md)
6. [Qt deployment](15-qt-deployment.md)
7. [Troubleshooting](16-troubleshooting.md)

## Hardware and Runtime

- [Architecture](ARCHITECTURE.md)
- [Device tree](06-device-tree.md)
- [I2C](07-i2c.md)
- [SPI](08-spi.md)
- [UART](09-uart.md)
- [USB](10-usb.md)
- [GPIO](11-gpio.md)
- [BLE](12-ble.md)
- [Display and touch](13-display-touch.md)
- [Systemd](14-systemd.md)
- [Network and SSH](05-network-and-ssh.md)

The documents reference local SDK installation paths where necessary. They do
not include SDK binaries, credentials, private keys, or generated build
products.
