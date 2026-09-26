# GitHub Submission Guide

This directory is a complete, curated source snapshot for publishing the
EdgePilot Launcher repository. The root `README.md` is the primary project
landing page.

Regenerated 2026-09-25 from the parent project. The file list is derived from
`qml.qrc` and `CMakeLists.txt` rather than maintained by hand, so the snapshot
cannot drift from what actually builds: every QML file, icon and texture here
is one the resource file embeds, and every `src/*.cpp` is one CMake compiles.
Verified by a clean `./build.sh` inside this directory, which produces an
aarch64 binary.

## Included

- Application source: `main.cpp`, `src/`, `qml/`, `assets/`, and `Clock/`
- AM62P build and deployment files, and the `edgepilot-*.service` units
- EVM helper assets: `evm-assets/`
- WSL, SDK, hardware, Qt, and deployment documentation: `docs/`
- Developer tooling: `tools/`, including the workbench GUI
- `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `ASSET_PROVENANCE.md`

## Excluded

- `build/` and `build-pc/`
- Generated binaries, object files, Qt caches, and simulator caches
- The Windows simulator (`win-sim/`)
- The TMP119 device-tree overlay and its notes (`dt-overlay/`). The launcher
  detects at runtime whether the kernel owns the I2C mux and drives it itself
  when nothing else has, so a board without the overlay still reads the
  sensor.
- The peripheral identification config (`config/`). See below.
- Private logs, backups, credentials, SSH keys, and Zone.Identifier files
- Unreviewed private or third-party assets
- Working notes and measurement logs kept alongside the parent project

## Bluetooth scope

The launcher ships one BLE workflow: the **BLE Scan** page, which pairs the
Apollo510b watchface firmware (advertised name `EdgePilot-510B`) using
six-digit numeric comparison, then subscribes to the Health Thermometer
characteristic `0x2A1C`.

Earlier builds carried several further BLE pages for third-party meters. They
were removed on 2026-09-25; `qml/Main.qml` keeps their `StackLayout` slots as
empty placeholders so the remaining pages hold their original indices.

## Device identification

Peripheral name fragments are **not** compiled in. `src/deviceprofiles.*`
reads them from a `device-profiles.json` supplied per deployment, which is not
part of this repository because it holds real device names. The header
documents each field and the lookup order; the file itself is:

```json
{
  "memoryMeterNamePrefix": "",
  "alwaysOnTokens": [],
  "vendor1524Tokens": [],
  "longHoldTokens": []
}
```

Looked up in this order, first hit wins: `$EDGEPILOT_DEVICE_PROFILES`, then a
`device-profiles.json` beside the executable, then
`/etc/edgepilot/device-profiles.json`. Finding none is not an error -- the
launcher starts normally and simply matches no device-specific special case.
Which file was used is logged once at first read.

The one exception is `EdgePilot-510B`, which is this project's own firmware
name and therefore ships with the code, in
`BleScanner::isApollo510Device()`.

## Deliberate differences from the parent project

`deploy.sh` no longer disables and deletes the pre-rename systemd units. That
block existed only to clean up a board carrying an install from before the
2026-09-13 rename; a board provisioned from this repository never had that
install, so the code was unreachable here and its only remaining effect was
to publish the former naming. The parent project keeps it, because its boards
may still need the upgrade path.

If you are upgrading a board that ran a pre-rename build, remove the old units
by hand before deploying this one.

The deployment scripts here also *require* `EVM_IP` instead of defaulting to
an address. A default only ever pointed at one particular lab board, and
silently copying files to someone else's address is worse than stopping.

## Before publishing

Review the ownership and license of every image, icon, font, SDK-derived file
and vendor dependency.

Third-party product and vendor names have been removed from the source,
comments, scripts and documentation. `config/device-profiles.json` is the
only place real peripheral names appear, and it is not tracked.
