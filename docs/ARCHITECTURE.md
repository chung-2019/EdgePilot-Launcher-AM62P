# EdgePilot Launcher Architecture

## Runtime layers

```text
QML pages and components
        |
        v
Qt Quick / Qt Quick 3D
        |
        v
Qt Quick Scene Graph -> Qt RHI
        |
        v
OpenGL ES RHI backend on AM62P
        |
        v
PowerVR graphics stack and display
```

The Earth-Moon page is implemented in QML with Qt Quick 3D components. The
application does not call OpenGL ES directly and does not link a custom shader
pipeline. Backend selection belongs to Qt and the installed EVM graphics
stack.

## Application layers

- `main.cpp` creates the Qt application, registers C++ backends, and loads
  `qrc:/qml/Main.qml`.
- `src/systemmonitor.*` reads system, thermal, storage, and network metrics.
- `src/benchmarkrunner.*` runs the configured benchmark commands and exposes
  their status to QML.
- `src/blescanner.*` drives the target image's `bluetoothctl` workflow and
  parses scan, connection, pairing, and temperature events.
- `src/uisyncserver.*` exposes the local UI state used by the simulator bridge.
- `qml/Main.qml` owns navigation, global dialogs, the lock screen, and the
  application layout.
- `qml/pages/` contains page-level workflows. `qml/earth3d/` contains the
  Earth, Moon, mission timeline, trajectories, and vehicle components.

## Navigation contract

`Main.qml` uses a `StackLayout` with stable page indices. New pages are appended
rather than inserted so BLE return paths and saved page state remain compatible.
Removed UI entries may leave a reserved placeholder index when external tools
still refer to the old number.

## Build boundary

The host provides CMake, Qt host tools, and the cross compiler. The TI sysroot
provides target Qt headers, libraries, and platform integration. Qt resources
are compiled from `qml.qrc` into the launcher binary; the EVM does not need a
checkout of the QML source to run the packaged launcher.

## UI state bridge

`src/uisyncserver.*` publishes the launcher's current page and BLE state as
read-only JSON for an external viewer. It binds to `127.0.0.1` only, so it is
not reachable from the network, and it accepts no commands -- the launcher
stays the single owner of `bluetoothctl`.

## Deployment boundary

`deploy.sh` stops the running service, copies the launcher and systemd units,
then enables the launcher service. It also deploys optional EVM helper assets.
The deploy target is supplied through `EVM_IP`, which the deployment scripts
require rather than default; no board address is compiled into the launcher or
built into a script. Addresses that appear in `docs/` are worked examples of a
LAN setup, not a network this project expects to find.
