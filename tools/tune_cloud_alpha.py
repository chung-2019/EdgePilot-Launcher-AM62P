#!/usr/bin/env python3
"""Re-grade the cloud layer alpha for assets/earth/earth_clouds_1k.png.

The cloud PNG that ships with the Earth/Moon asset pack is a full-coverage
procedural noise field: mean alpha 0.29 with only ~8% of pixels near
transparent and visible posterisation banding. Wrapped on a sphere it reads
as grey fog over the whole planet rather than as weather, and it hides the
continents completely.

This rebuilds it as an actual cloud mask:
  1. box-blur the alpha (wrapping in longitude) to kill the banding steps,
  2. push it through a smoothstep window so only the denser blobs survive,
  3. force RGB to white, so low-alpha texels cannot tint the blend.

Source stays untouched in am62p-earth-moon/assets/; only the copy under
assets/ that gets compiled into the qrc is regraded.

Run (from the project root, WSL):
    python3 tools/tune_cloud_alpha.py
"""

import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "am62p-earth-moon" / "assets" / "earth" / "earth_clouds_1k.png"
DST = ROOT / "assets" / "earth" / "earth_clouds_1k.png"

BLUR_RADIUS = 3        # texels, applied twice
BLUR_PASSES = 2
LO = 0.36              # alpha below this becomes fully clear
HI = 0.72              # alpha above this becomes fully opaque


def read_png_rgba(path: Path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"

    pos, idat = 8, b""
    w = h = depth = colour = None
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            w, h, depth, colour = struct.unpack(">IIBB", body[:10])
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break

    if depth != 8 or colour != 6:
        sys.exit(f"expected 8-bit RGBA, got depth={depth} colour={colour}")

    raw = zlib.decompress(idat)
    bpp, stride = 4, w * 4
    out = bytearray(h * stride)

    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        base, prev = y * stride, (y - 1) * stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = out[prev + i] if y > 0 else 0
            c = out[prev + i - bpp] if (y > 0 and i >= bpp) else 0
            x = line[i]
            if f == 1:
                x += a
            elif f == 2:
                x += b
            elif f == 3:
                x += (a + b) // 2
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                x += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = x & 0xFF
            out[base + i] = line[i]
    return w, h, out


def box_blur(alpha, w, h, radius):
    """Separable running-sum box blur. Wraps in x (longitude), clamps in y."""
    span = 2 * radius + 1

    tmp = [0.0] * (w * h)
    for y in range(h):
        row = alpha[y * w:(y + 1) * w]
        acc = sum(row[(-radius + i) % w] for i in range(span))
        base = y * w
        for x in range(w):
            tmp[base + x] = acc / span
            acc += row[(x + radius + 1) % w] - row[(x - radius) % w]

    out = [0.0] * (w * h)
    for x in range(w):
        col = [tmp[y * w + x] for y in range(h)]
        acc = sum(col[min(max(i - radius, 0), h - 1)] for i in range(span))
        for y in range(h):
            out[y * w + x] = acc / span
            acc += col[min(y + radius + 1, h - 1)] - col[max(y - radius, 0)]
    return out


def chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main() -> None:
    w, h, px = read_png_rgba(SRC)
    print(f"source {SRC.name}: {w}x{h}")

    alpha = [float(px[i]) for i in range(3, len(px), 4)]
    for _ in range(BLUR_PASSES):
        alpha = box_blur(alpha, w, h, BLUR_RADIUS)

    rows = bytearray()
    kept = 0
    for y in range(h):
        rows.append(0)  # filter type None
        base = y * w
        for x in range(w):
            t = (alpha[base + x] / 255.0 - LO) / (HI - LO)
            t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
            t = t * t * (3.0 - 2.0 * t)  # smoothstep
            a = int(t * 255.0 + 0.5)
            if a > 8:
                kept += 1
            rows += bytes((255, 255, 255, a))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")

    DST.write_bytes(png)
    print(f"wrote {DST} ({len(png)} bytes), cloud coverage {100.0 * kept / (w * h):.1f}%")


if __name__ == "__main__":
    main()
