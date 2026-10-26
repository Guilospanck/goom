#!/usr/bin/env python3
"""Renders Resources/AppIcon.png (1024x1024) with no dependencies. build-app.sh turns it into an .icns."""
import math, struct, zlib, os

N = 1024
C = N / 2

def sdf_round_rect(x, y, half, r):
    qx, qy = abs(x - C) - (half - r), abs(y - C) - (half - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r

def cover(d):  # signed distance -> antialiased coverage
    return min(max(0.5 - d, 0), 1)

def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

TOP, BOTTOM = (255, 94, 98), (122, 60, 255)
rows = []
for py in range(N):
    row = bytearray([0])
    for px in range(N):
        x, y = px + 0.5, py + 0.5
        a = cover(sdf_round_rect(x, y, 412, 185))
        if a == 0:
            row += bytes((0, 0, 0, 0)); continue
        col = mix(TOP, BOTTOM, (x + y) / (2 * N))
        r = math.hypot(x - C, y - C)
        ring = cover(abs(r - 250) - 34)
        dot = cover(r - 130)
        w = max(ring, dot)
        col = mix(col, (255, 255, 255), w)
        row += bytes((int(col[0]), int(col[1]), int(col[2]), int(a * 255)))
    rows.append(bytes(row))

def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d))

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
out = os.path.join(os.path.dirname(__file__), "..", "Resources", "AppIcon.png")
open(out, "wb").write(png)
print("wrote", os.path.normpath(out))
