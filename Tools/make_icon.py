"""
Generates the MissionFocus addon icon (Icons/icon.tga, 64x64 32-bit TGA), used
by the .toc files (## IconTexture) for the AddOns list.

The icon: a gold focus reticle (ring with four ticks) around a quest "!",
on a dark round badge.

Usage:  python make_icon.py [icons_dir] [preview_png]
No dependencies. Shapes are signed distance functions, so edges are
anti-aliased without supersampling.
"""
import math
import os
import struct
import sys
import zlib

SIZE = 64

BADGE = (0.07, 0.09, 0.14)      # dark blue-grey background
BADGE_EDGE = (0.02, 0.02, 0.03)  # outer outline
GOLD = (1.0, 0.82, 0.18)         # quest gold
GOLD_DARK = (0.55, 0.36, 0.05)   # bottom of the gold gradient
OUTLINE = (0.03, 0.02, 0.0)      # outline around gold shapes


# ---------------------------------------------------------------- SDF primitives
# Coordinates: (0, 0) top-left, (1, 1) bottom-right. Negative = inside.

def sd_circle(p, c, r):
    return math.hypot(p[0] - c[0], p[1] - c[1]) - r


def sd_box(p, c, half, r=0.0):
    qx = abs(p[0] - c[0]) - half[0] + r
    qy = abs(p[1] - c[1]) - half[1] + r
    outside = math.hypot(max(qx, 0), max(qy, 0))
    return outside + min(max(qx, qy), 0) - r


def sd_capsule(p, a, b, r):
    """Segment a-b with radius r, wider at a (ra) than at b: a tapered bar."""
    pa = (p[0] - a[0], p[1] - a[1])
    ba = (b[0] - a[0], b[1] - a[1])
    h = max(0.0, min(1.0, (pa[0] * ba[0] + pa[1] * ba[1]) / (ba[0] ** 2 + ba[1] ** 2)))
    rr = r[0] + (r[1] - r[0]) * h
    return math.hypot(pa[0] - ba[0] * h, pa[1] - ba[1] * h) - rr


# ---------------------------------------------------------------- shapes

C = (0.5, 0.5)


def s_badge(p):
    return sd_circle(p, C, 0.47)


def s_gold(p):
    """Reticle ring + four ticks + exclamation mark (all gold)."""
    ring = abs(sd_circle(p, C, 0.315)) - 0.035
    # Ticks cross the ring at top, bottom, left and right.
    ticks = min(
        sd_box(p, (0.5, 0.165), (0.03, 0.075), 0.015),
        sd_box(p, (0.5, 0.835), (0.03, 0.075), 0.015),
        sd_box(p, (0.165, 0.5), (0.075, 0.03), 0.015),
        sd_box(p, (0.835, 0.5), (0.075, 0.03), 0.015),
    )
    bar = sd_capsule(p, (0.5, 0.33), (0.5, 0.56), (0.055, 0.035))
    dot = sd_circle(p, (0.5, 0.665), 0.05)
    return min(ring, ticks, bar, dot)


def coverage(d, px):
    return max(0.0, min(1.0, 0.5 - d / px))


def over(dst, src, a):
    """Alpha-composite colour src with coverage a over premultiplied dst (r, g, b, a)."""
    r, g, b, da = dst
    return (src[0] * a + r * (1 - a), src[1] * a + g * (1 - a), src[2] * a + b * (1 - a), a + da * (1 - a))


def render():
    px = 1.0 / SIZE
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            p = ((x + 0.5) * px, (y + 0.5) * px)
            col = (0.0, 0.0, 0.0, 0.0)

            # Badge with a dark rim and a soft radial light from the top.
            db = s_badge(p)
            col = over(col, BADGE_EDGE, coverage(db, px))
            light = 1.0 + 0.6 * max(0.0, 1 - math.hypot(p[0] - 0.5, p[1] - 0.3) / 0.45)
            inner = tuple(min(1.0, c * light) for c in BADGE)
            col = over(col, inner, coverage(db + 0.03, px))

            # Gold shapes: dark outline, then a vertical gold gradient.
            dg = s_gold(p)
            col = over(col, OUTLINE, coverage(dg - 0.03, px))
            t = p[1]
            gold = tuple(g + (gd - g) * t ** 1.5 for g, gd in zip(GOLD, GOLD_DARK))
            col = over(col, gold, coverage(dg, px))

            # Un-premultiply for the file.
            a = col[3]
            if a > 0:
                row.append((col[0] / a, col[1] / a, col[2] / a, a))
            else:
                row.append((0.0, 0.0, 0.0, 0.0))
        rows.append(row)
    return rows


# ---------------------------------------------------------------- output

def write_tga(path, pixels):
    h, w = len(pixels), len(pixels[0])
    # Uncompressed true-colour, 32 bpp, 8 alpha bits, top-left origin.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    data = bytearray()
    for row in pixels:
        for r, g, b, a in row:
            data += bytes((int(b * 255 + 0.5), int(g * 255 + 0.5), int(r * 255 + 0.5), int(a * 255 + 0.5)))
    with open(path, "wb") as f:
        f.write(header + bytes(data))


def write_preview(path, pixels, scale=4, bg=0.35):
    """The icon enlarged on a mid-grey background (PNG)."""
    h, w = len(pixels) * scale, len(pixels[0]) * scale
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            r, g, b, a = pixels[y // scale][x // scale]
            for c in (r, g, b):
                raw.append(int((c * a + bg * (1 - a)) * 255 + 0.5))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "Icons")
    os.makedirs(out_dir, exist_ok=True)
    img = render()
    write_tga(os.path.join(out_dir, "icon.tga"), img)
    print("wrote icon")
    if len(sys.argv) > 2:
        write_preview(sys.argv[2], img)
        print("preview", sys.argv[2])


if __name__ == "__main__":
    main()
