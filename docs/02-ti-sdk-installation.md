# 2. Installing the TI Processor SDK

The SDK provides the cross toolchain, the target sysroot, a matching kernel
source tree and the device-tree sources. Everything else in this repository
assumes it is installed and working.

## Get the installer

From TI's Processor SDK Linux page for AM62Px, download

```
ti-processor-sdk-linux-am62pxx-evm-<version>-Linux-x86-Install.bin
```

It is around 4.5 GB. The version matters later — the Qt in its sysroot decides
which host Qt you need — so note it down.

## Install it unattended

The installer is a BitRock InstallBuilder package, which means it has a silent
mode. There is no reason to sit through the GUI:

```bash
chmod +x ti-processor-sdk-linux-*-Install.bin

sudo ./ti-processor-sdk-linux-*-Install.bin \
     --mode unattended \
     --unattendedmodeui none \
     --prefix /opt/ti/processor-sdk-linux-am62pxx \
     --installer-language en
```

It prints nothing for 10–40 minutes. That is normal — check with `top` in
another window if you need reassurance.

The GUI's **SDK Setup** panel runs exactly this and streams the output.

### Under WSL, copy the installer to the Linux filesystem first

```bash
cp /mnt/c/Users/you/Downloads/ti-processor-sdk-*.bin /tmp/
sudo /tmp/ti-processor-sdk-*.bin --mode unattended ...
```

Running it directly from `/mnt/c` works but takes several times longer: the
installer writes tens of thousands of small files, and every one of them crosses
the 9p boundary. Needs ~4.5 GB of temporary space.

## Fix the ownership immediately

This is the single most common "the SDK is broken" report, and it is not the
SDK.

The install runs as root, so everything it wrote is owned by root. Your first
build as a normal user then fails with `Permission denied` somewhere inside the
example applications — a long way from anything that mentions ownership.

```bash
sudo chown -R "$(id -un):$(id -gn)" /opt/ti/processor-sdk-linux-am62pxx/example-applications
```

The GUI does this automatically: it detects the everyday account before
installing and hands it the workspace afterwards.

## Verify

```bash
./scripts/verify_sdk.sh
```

It checks the environment script, the cross compiler and its target triple, the
sysroot, the SDK's own cmake and ninja, the workspace permissions, the host Qt
if the profile names one — and then actually compiles and links a hello-world
for the target, which is the only check that proves the rest.

Expected:

```
[OK] environment script: .../linux-devkit/environment-setup
[OK] cross compiler: aarch64-oe-linux-gcc (GCC) 15.2.0
[OK] targets aarch64-oe-linux
[OK] target sysroot: .../sysroots/aarch64-oe-linux
[OK] built a target binary: ELF 64-bit LSB pie executable, ARM aarch64
```

The exit code is the number of failed checks, so it can gate a build script.

## What is in there

```
/opt/ti/processor-sdk-linux-am62pxx/
├── linux-devkit/
│   ├── environment-setup            source this before every build
│   └── sysroots/
│       ├── x86_64-arago-linux/      the compiler itself, cmake, ninja
│       └── aarch64-oe-linux/        target headers and libraries
├── board-support/
│   ├── ti-linux-kernel-*/           kernel source and device-tree sources
│   └── ti-u-boot-*/                 bootloader source
├── example-applications/            where your projects go
└── filesystem/                      prebuilt images
```

Two directories get used constantly: `environment-setup`, and
`board-support/ti-linux-kernel-*/arch/arm64/boot/dts/ti/` for device-tree work.

## Point the board profile at it

If you installed somewhere else, edit `board_profiles/sk-am62p-lp.yaml`:

```yaml
sdk:
  root: /path/to/your/sdk
```

Everything — the GUI, the scripts, the examples — reads that one value.

## Note the Qt version now

If your application uses Qt:

```bash
ls /opt/ti/processor-sdk-linux-am62pxx/linux-devkit/sysroots/aarch64-oe-linux/usr/lib/libQt6Core.so.*
```

The soname carries the version, for example `libQt6Core.so.6.12.0`. You will
need a **host** Qt of exactly that version to cross compile against it:

```bash
./scripts/install_host.sh --with-qt 6.12.0
```

See `15-qt-deployment.md` for why, and for what to do when that version is not
downloadable.

## Next

`03-cross-compilation.md`
