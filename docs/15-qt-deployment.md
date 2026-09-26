# 15. Qt: cross compiling and deploying

Qt cross compilation has three failure modes that produce error messages pointing
nowhere near their cause. All three are reproduced, diagnosed and fixed in
`examples/hello-qt/` — this document is why each fix works.

## You need Qt twice

| | Where | What for |
|---|---|---|
| **target Qt** | the SDK sysroot | the libraries linked into the binary, built for aarch64 |
| **host Qt** | the build machine | `moc`, `rcc`, `qmlcachegen` — programs that must run *here* |

The SDK ships the first and not the second. Find the version you need:

```bash
ls $SDK/linux-devkit/sysroots/aarch64-oe-linux/usr/lib/libQt6Core.so.*
# libQt6Core.so.6.12.0   ->  you need host Qt 6.12.0
```

Install it:

```bash
scripts/install_host.sh --with-qt 6.12.0
```

That uses aqtinstall into its own venv under `/opt/qt-aqt-venv`, and puts Qt in
`/opt/Qt/<version>/gcc_64`.

## Failure 1: version mismatch

Qt requires the host tools to be the **same version** as the target libraries.
With a mismatch, CMake says:

```
CMake Error at CMakeLists.txt:14 (find_package):
  Found package configuration file: .../Qt6Config.cmake
  but it set Qt6_FOUND to FALSE
  Reason given by package: Failed to find required Qt component "Core"
```

Which is not the reason. The reason is three `find_package` levels up, in a
*warning* that scrolled past:

```
Could not find a configuration file for package "Qt6CoreTools" that is
compatible with requested version "6.12.0".
  /opt/Qt/6.11.0/.../Qt6CoreToolsConfig.cmake, version: 6.11.0
```

`build.sh` compares the two versions before invoking CMake and says so directly.

**If the exact version is not downloadable** — a Yocto SDK can carry a Qt that
was never released to the download servers — the options are:

* build the host tools from the same Qt source tree (`qtbase` configured for the
  host, `-nomake examples -nomake tests`; it takes a while but works);
* use `qt6-native` from the same Yocto build, if you have access to it;
* or rebuild the SDK against a Qt version you can get.

There is no way around the requirement itself.

## Failure 2: `ZSH_NAME: unbound variable`

```
environment-setup: line 2: ZSH_NAME: unbound variable
```

The SDK environment script reads variables it never sets. Any build script using
`set -u` — which it should — aborts while sourcing it. Turn it off for that one
line:

```bash
set +u
source "$ENV_SETUP"
set -u
```

Related: the environment script is bash, so a `#!/bin/sh` script cannot source it
at all on a system where `/bin/sh` is dash.

## Failure 3: `stdlib.h: No such file or directory`

```
.../usr/include/c++/15.2.0/cstdlib:83:15: fatal error: stdlib.h: No such file or directory
   83 | #include_next <stdlib.h>
```

The header is right there in the sysroot. The compiler is fine. **CMake is adding
a flag that breaks the include chain.**

Qt's headers live under `<sysroot>/usr/include`, and CMake adds an imported
target's include directories with `-isystem`. That pushes `<sysroot>/usr/include`
*ahead of* the C++ standard headers in the search order. libstdc++'s `<cstdlib>`
then does `#include_next <stdlib.h>`, which searches only directories *after* its
own — and `/usr/include` is now before it. So the header cannot be found.

The fix is one line:

```cmake
set(CMAKE_NO_SYSTEM_FROM_IMPORTED ON)
```

Imported include directories become `-I` instead of `-isystem`, and CMake filters
its own implicit include directories out of `-I` lists — `<sysroot>/usr/include`
is one of them, so the bad flag disappears. The only cost is that warnings from
Qt headers are no longer suppressed.

What does **not** work, in case you try it:

* passing `--sysroot`: the compiler was never the problem;
* setting `CMAKE_SYSROOT`: the OE toolchain file already sets it;
* appending to `CMAKE_<LANG>_IMPLICIT_INCLUDE_DIRECTORIES`: the directory is
  already in there, which is exactly why the `-I` filter works.

## Configuring a Qt cross build

```bash
set +u; source "$SDK/linux-devkit/environment-setup"; set -u

cmake -S . -B build \
      -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
      -DCMAKE_BUILD_TYPE=Release \
      -DQT_HOST_PATH=/opt/Qt/6.12.0/gcc_64 \
      -DQT_HOST_PATH_CMAKE_DIR=/opt/Qt/6.12.0/gcc_64/lib/cmake
cmake --build build -j"$(nproc)"
file build/myapp        # must say ARM aarch64
```

## QRC or qt_add_qml_module?

`qt_add_qml_module` is the modern way and gives you compiled QML, but it pulls in
more host tools (`qmlcachegen`, `qmltyperegistrar`), each of which is another
version-matching opportunity. For a first cross build, a plain `.qrc` with
`CMAKE_AUTORCC` needs only `moc` and `rcc`. The example uses the QRC route
deliberately.

## Running it on the board

```bash
QT_QPA_PLATFORM=wayland /usr/bin/hello-qt
```

Environment variables worth knowing:

| Variable | Use |
|---|---|
| `QT_QPA_PLATFORM=wayland` | normal case, through the compositor |
| `QT_QPA_PLATFORM=eglfs` | no compositor: Qt drives DRM directly |
| `QT_QPA_PLATFORM=vnc:size=1280x800` | render to VNC — no display needed |
| `QT_QUICK_BACKEND=software` | required with VNC (no GL context) |
| `QT_LOGGING_RULES=qt.qpa.*=true` | what platform plugin was chosen, and why it failed |

That last one is the first thing to set when a Qt application starts and shows
nothing.

## VNC: a second instance, not a mirror

Starting a second instance with `QT_QPA_PLATFORM=vnc` is genuinely useful for a
board with no panel attached — same binary, same hardware, no code change.

It is **not** a view of what the panel is showing. It is a separate process with
its own state, so:

* kernel-mediated resources (I2C, sysfs) are serialised and both instances read
  them happily;
* exclusive resources are not. A serial port opened by one is unavailable to the
  other, and two processes driving one Bluetooth adapter will interfere with each
  other's pairing and notifications.

Keep the remote instance on read-only screens. And Qt's VNC server speaks RFB 3.3
with no authentication — tunnel it:

```bash
ssh -N -L 5900:127.0.0.1:5900 root@192.168.0.42
```

The GUI's **Remote UI** panel starts, stops and tunnels this.

## What to ship to the board

The binary is not enough on its own:

| | |
|---|---|
| the binary | `/usr/bin/myapp` |
| the systemd unit | see `14-systemd.md` |
| QML not in the QRC | keep it in the QRC and this problem disappears |
| fonts | a stock image may have very few; missing glyphs look like a layout bug |
| Qt plugins | already in the image if the target Qt came from the SDK |

`examples/hello-qt/deploy.sh` handles the first two, and disables the stock demo
launchers that would otherwise fight for the display.

## Related

* `examples/hello-qt/` — all three failures, reproduced and fixed
* `docs/03-cross-compilation.md`
* `docs/13-display-touch.md`

## Next

`16-troubleshooting.md`
