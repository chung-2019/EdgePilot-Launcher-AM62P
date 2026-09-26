# Asset Provenance

This file records the provenance boundary for visual resources included in
this repository. It intentionally avoids private filesystem paths,
conversation transcripts, and unrelated project material.

## Earth and Moon resources

The Earth and Moon texture resources are project-specific visual assets used
for demonstration. They are not scientific, meteorological, terrain, or
navigation data. The source images and processing records should be retained
by the project owner outside the public repository when a complete audit trail
is required.

The runtime resources are registered through `qml.qrc` and consumed by the
Qt Quick 3D scene under `qml/earth3d/`. They are distributed only as part of
this application source unless their individual source terms state otherwise.

## Brand and UI assets

Files under `assets/` include project branding, interface artwork, icons, and
hardware demonstration images. Before publishing a public release, confirm
that each image, logo, icon, and font has a documented right to redistribute.
Do not treat a file's presence in the working tree as proof of ownership.

## Generated and derived assets

Some visual resources are generated or derived for presentation and testing.
They should not be represented as measurements or official hardware data.
Derived files remain subject to the rights of their source materials. Where
rights cannot be confirmed, keep the resource private or replace it with an
asset whose license is documented.

## Reproducibility

The public repository records the resource role and dependency boundary, but
not private source paths. Any future conversion or optimization should record:

- source asset name and license
- tool and version used
- output dimensions and pixel format
- transformation or compression steps
- a checksum of the published output

## Ownership and release review

The project BSD-3-Clause license applies only to project-owned assets for which
the project owner holds the necessary rights. Third-party assets retain their
own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
