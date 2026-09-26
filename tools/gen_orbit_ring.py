#!/usr/bin/env python3
"""One-shot generator for assets/space/moon_orbit_ring.png.

Qt Quick 3D has no line primitive and no TorusGeometry, and this project
cannot link the Quick3D C++ API (the AM62P devkit sysroot ships no Quick3D
headers — only the EVM rootfs has the runtime). So the moon orbit line is a
single textured "#Rectangle" plane laid flat in the XZ plane: one draw call,
two triangles, and the alpha ring is anti-aliased by the texture itself.

The ring sits at 0.80 of the plane half-extent so the soft halo still has
room before the texture edge. EarthMoonScene.qml relies on that constant.

Run (from the project root, WSL):
    python3 tools/gen_orbit_ring.py
"""

import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
RING_R = 0.80          # ring radius, normalised to the half-extent
CORE_W = 0.0035        # crisp line half-width
HALO_W = 0.030         # soft glow half-width
HALO_A = 0.22          # glow peak alpha
RGB = (150, 176, 214)  # cool grey-blue, matches the doc's "#8e98a8" intent

OUT = Path(__file__).resolve().parent.parent / "assets" / "space" / "moon_orbit_ring.png"


def chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main() -> None:
    centre = (SIZE - 1) / 2.0
    half = SIZE / 2.0
    r, g, b = RGB

    rows = bytearray()
    for y in range(SIZE):
        dy = (y - centre) / half
        rows.append(0)  # PNG filter type 0 (None) for this scanline
        for x in range(SIZE):
            dx = (x - centre) / half
            d = math.hypot(dx, dy) - RING_R
            core = math.exp(-(d / CORE_W) ** 2) if abs(d) < CORE_W * 6 else 0.0
            halo = HALO_A * math.exp(-(d / HALO_W) ** 2) if abs(d) < HALO_W * 6 else 0.0
            a = core + halo
            a = 255 if a >= 1.0 else int(a * 255.0 + 0.5)
            rows += bytes((r, g, b, a))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(png)
    print(f"wrote {OUT} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
