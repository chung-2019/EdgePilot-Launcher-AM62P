# 3. Cross compilation

One rule covers most of it: **source the environment script, then build
normally.**

```bash
source /opt/ti/processor-sdk-linux-am62pxx/linux-devkit/environment-setup
make                    # or cmake, or ./build.sh
```

## What sourcing it actually does

It exports a set of variables that make ordinary build systems produce target
binaries without knowing anything about cross compilation:

```bash
CC=aarch64-oe-linux-gcc --sysroot=/opt/ti/.../sysroots/aarch64-oe-linux
CXX=aarch64-oe-linux-g++ --sysroot=...
CFLAGS=-O2 -mbranch-protection=standard -fstack-protector-strong ...
CMAKE_TOOLCHAIN_FILE=.../OEToolchainConfig.cmake
PKG_CONFIG_SYSROOT_DIR=...
PATH=<SDK compiler directory>:$PATH
```

Note that `CC` is *two words* — the compiler plus its `--sysroot`. Anything that
treats `$CC` as a single filename breaks. Use it unquoted in shell, and let make
and cmake handle it.

Without the sysroot the compiler cannot find its own headers. Invoke
`aarch64-oe-linux-gcc` directly and you get `fatal error: stdio.h: No such file
or directory` — which looks like a broken installation and is not.

## Makefile projects

```make
CC      ?= cc
CFLAGS  ?= -O2
CFLAGS  += -Wall -Wextra
```

`?=` is the point: it leaves the environment's value alone when there is one,
and falls back to a host build when there is not. See `examples/hello-c/`.

## CMake projects

```bash
source .../environment-setup
cmake -S . -B build \
      -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
      -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
```

Pass the toolchain file explicitly. It is what sets `CMAKE_SYSROOT` and the
find-root modes, so `find_package` and `find_library` look inside the sysroot
instead of on the build host. Without it, CMake happily finds a host library and
the failure surfaces much later, somewhere unrelated.

## Always check the result

```bash
file build/myapp
# ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV) ...
```

If it says `x86-64`, the environment was not sourced. Deploying it gives
`cannot execute binary file: Exec format error` on the board — an error that
says nothing about the cause, which is why both examples check the architecture
in `make check` and refuse to deploy the wrong one.

## Three snags worth knowing before you hit them

**`ZSH_NAME: unbound variable`.** The environment script reads variables it never
sets. A build script with `set -u` aborts while sourcing it:

```bash
set +u
source "$ENV_SETUP"
set -u
```

**The environment script is bash.** Sourcing it from `#!/bin/sh` (dash on
Debian and Ubuntu) fails on its syntax. Use `#!/bin/bash` in any script that
sources it.

**It does not stack.** Sourcing two SDKs in one shell leaves a mixture that
builds against one sysroot with the other's compiler. Use a fresh shell per SDK.

## Sourcing in a subshell

To avoid contaminating your interactive shell:

```bash
bash -c 'set +u; source /opt/ti/.../environment-setup; make'
```

That is what `verify_sdk.sh` does for its smoke test.

## Static and dynamic libraries

Link against libraries from the **sysroot**, never from the host:

```bash
pkg-config --cflags --libs libfoo      # correct after sourcing: sysroot-aware
```

The environment sets `PKG_CONFIG_SYSROOT_DIR` and `PKG_CONFIG_PATH` for exactly
this. A path like `/usr/lib/x86_64-linux-gnu/...` appearing in your link line
means something reached onto the host.

## What runs where

| Runs on the build host | Runs on the board |
|---|---|
| gcc, g++, ld | the built binary |
| cmake, make, ninja | |
| Qt's moc, rcc, qmlcachegen | Qt libraries |
| the device-tree compiler, for building | `dtc -I fs`, for inspecting the live tree |

The Qt row is the one that causes trouble; see `15-qt-deployment.md`.

## Try it

```bash
cd examples/hello-c
make            # without sourcing first: a host build
make check      # tells you so
source /opt/ti/processor-sdk-linux-am62pxx/linux-devkit/environment-setup
make clean && make && make check
```

Doing it wrong once, deliberately, is worth more than reading about it.

## Next

`04-evm-first-boot.md`
