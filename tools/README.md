# tools/

Developer tooling. Most of it you run once, when moving to a new machine or
bringing someone new onto the project.

## EdgePilot_Workbench.pyw

A tkinter GUI for Windows that turns the whole loop -- install the SDK,
cross-compile, deploy, probe the board -- into buttons. The interface and its
log are English.

It runs under Windows `python.exe`, which ships tkinter; WSL's `python3` does
not have it. The actual work happens inside WSL through `wsl.exe`, and board
access uses WSL's own ssh keys. Standard library only, no third-party
packages.

```
pythonw EdgePilot_Workbench.pyw
```

| Tab | What it does |
| --- | --- |
| 1. Install SDK | Silent TI SDK install, Qt host toolchain (aqtinstall), build-essential |
| 2. CC3351 Wi-Fi | Pings a hostname forced out of wlan0 -- one test covers association, routing, DNS and reachability |
| 3. Cross-compile + Deploy | Runs `build.sh` then `deploy.sh`; the project path is not hard-coded |
| 4. Password SSH | For a board that only accepts a password (sshpass reads it from SSHPASS) |
| 5. BLE Scan Step | Persistent bluetoothctl, driven one command at a time per the BLE Scan flow |

Tab 5 mirrors the launcher's **BLE Scan** page: it pairs the Apollo510b
watchface firmware (advertised name `EdgePilot-510B`) using six-digit numeric
comparison. It shares the command sequence and the HTS temperature decoding
with `src/blescanner.cpp`; the only difference is that a local QProcess is
replaced by an SSH hop into the board.

One thing worth knowing: the subscribe sequence issues **no `read`**.
Apollo510b declares `0x2A1C` as `ATT_PROP_INDICATE` only, so `read` returns
`org.bluez.Error.NotPermitted`, and the extra ATT round-trip only delays
`notify on` -- which is the one step that makes the firmware start sending.
It emits the first sample once the CCCD is armed, then one per second. This
matches `doRead = !m_standardMode && !isApollo510Device()` in the launcher.

`loadConnParams` (raw MGMT opcode 0x0035) is not a bluetoothctl command and is
therefore not in this tool; use the launcher app to tune connection
parameters.

## fresh-laptop-setup.sh

One-shot setup for a new development machine.

```bash
./fresh-laptop-setup.sh /path/to/processor-sdk-linux-am62pxx-evm-X.X.X.XX-Linux-x86-Install.bin
```

It does four things:

1. `apt-get install` of the required packages (python3-venv, cmake,
   build-essential and friends)
2. Runs the TI Processor SDK installer with `--mode unattended`
3. Creates a venv, installs aqtinstall, and downloads the Qt 6.11.0 host
   toolchain into `/opt/Qt/`
4. Verifies that the cross compiler, moc and rcc can all be invoked

It is **idempotent**: steps that are already done are skipped, so re-running
is safe.

### Prerequisites

- Ubuntu 22.04+ or WSL2 Ubuntu
- sudo access
- The TI SDK installer `.bin` from
  https://www.ti.com/tool/PROCESSOR-SDK-AM62P
- About 10 GB of disk (SDK 8 GB, Qt 1.5 GB, apt 0.5 GB)

### Afterwards

```bash
cd /opt/ti/processor-sdk-linux-am62pxx/example-applications/EdgePilot_Github_Demo
source /opt/ti/processor-sdk-linux-am62pxx/linux-devkit/environment-setup
./build.sh
EVM_IP=<board address> ./deploy.sh
```

The first time you touch a new board, also run:

```bash
cd evm-assets
EVM_IP=<board address> ./push-evm-assets.sh
```

### When it fails

| Symptom | What to do |
| --- | --- |
| The SDK installer insists on a GUI | Some versions of TI's bitrock installer do not support unattended mode. Run it once by hand: `./xxx.bin` |
| `aqt list-qt linux desktop` does not show 6.11.0 | aqtinstall is too old: `/opt/qt-aqt-venv/bin/pip install -U aqtinstall` |
| moc complains about the GLIBC version | The host Ubuntu is too old (< 22.04). Upgrade it, or use Qt 6.10 |

## gen_orbit_ring.py, tune_cloud_alpha.py

Asset generators for the Earth 3D scene: the Moon's orbit ring texture and the
cloud-layer alpha. They are here so the shipped textures can be reproduced
rather than only inherited. Neither is needed to build or run the launcher.

## touch_lines_state.sh

Dumps the touchscreen's input state from the board -- controller, driver
binding and event device. Useful when touch stops responding and you need to
tell "no device" apart from "device present, driver not bound".
