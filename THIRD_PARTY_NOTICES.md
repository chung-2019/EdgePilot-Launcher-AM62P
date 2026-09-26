# Third-Party Notices

This repository contains EdgePilot application code and integration files. It
is not a redistribution of the complete SDKs or runtimes listed below.
Third-party files and assets retain their original notices and license terms.

## Qt 6

The application uses Qt 6 modules including Qt Core, Gui, Network, QML, Quick,
Quick Controls 2, SVG, and Qt Quick 3D at runtime. Qt is obtained separately
from the Qt project or the TI EVM image. Review the applicable Qt open-source
license terms, including LGPL/GPL requirements and Qt's dynamic-linking and
notice obligations, before distributing binaries.

This repository does not include the Qt runtime libraries or host tools.

## Texas Instruments Processor SDK

The AM62P target headers, libraries, boot files, kernel, device-tree files, and
runtime components come from the Texas Instruments Processor SDK Linux
installation and the target EVM image. They are not included here. Review the
license files shipped with the exact Processor SDK release and target image.

## Qt Quick 3D and graphics drivers

Earth-Moon rendering uses Qt Quick 3D and the Qt 6 scene graph/RHI. The EVM
selects the OpenGL ES RHI backend through its installed graphics stack. PowerVR
or other graphics-driver binaries are supplied by the board image and are not
redistributed here.

## BlueZ and Linux utilities

BLE workflows invoke the target image's `bluetoothctl` and related BlueZ
services. System utilities, kernel interfaces, and their licenses are supplied
by the target Linux distribution and are outside this repository.

## Fonts and image assets

Font packages installed by `evm-assets/` are fetched from their respective
providers at deployment time. Their licenses and notices must be retained on
the target system. Image provenance and processing notes are documented in
[ASSET_PROVENANCE.md](ASSET_PROVENANCE.md).

## No endorsement

Product names including Qt, Texas Instruments, AM62P, PowerVR, BlueZ, and
OpenGL ES belong to their respective owners. This independent project is not
endorsed, sponsored, certified, or approved by those organizations.
