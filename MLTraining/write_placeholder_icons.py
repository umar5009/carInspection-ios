"""Write the App Icon and launch logo the asset catalog already references.

Uses only the Python standard library so the Xcode project can compile
without Pillow. Replace these with MLTraining/generate_icon.py when Pillow
is available.
"""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "Carlyze/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
LOGO = ROOT / "Carlyze/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.png"

NAVY = (12, 24, 52)
TEAL = (4, 60, 78)
MINT = (0, 224, 184)
WHITE = (245, 250, 255)
INK = (8, 28, 56)


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def png(path, width, height, rgba):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(rgba(x, y))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    path.write_bytes(data)


def inside_poly(x, y, pts):
    n = len(pts)
    c = False
    j = n - 1
    for i in range(n):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi + 1e-9) + xi):
            c = not c
        j = i
    return c


def render(size, rounded):
    w = size * 0.66
    h = w * 0.38
    x0 = size * 0.5 - w / 2
    y0 = size * 0.55 - h / 2

    def P(px, py):
        return (x0 + px * w, y0 + py * h)

    body = [
        P(0.02, 0.60), P(0.06, 0.46), P(0.24, 0.38), P(0.36, 0.35),
        P(0.46, 0.10), P(0.52, 0.05), P(0.70, 0.05), P(0.79, 0.12),
        P(0.88, 0.34), P(0.97, 0.40), P(0.99, 0.55), P(0.98, 0.80), P(0.02, 0.80),
    ]
    windows = [
        [P(0.43, 0.35), P(0.495, 0.14), P(0.59, 0.12), P(0.59, 0.35)],
        [P(0.62, 0.35), P(0.62, 0.12), P(0.69, 0.12), P(0.78, 0.35)],
    ]
    wheels = []
    for wx in (0.22, 0.79):
        wheels.append((x0 + wx * w, y0 + 0.80 * h, h * 0.235))
    sy = size * 0.545
    margin = size * 0.08
    radius = size * 0.225 if rounded else 0

    def bracket(x, y):
        box = (size * 0.16, size * 0.24, size * 0.84, size * 0.84)
        x0b, y0b, x1b, y1b = box
        L = (x1b - x0b) * 0.17
        thick = size * 0.018
        for cx, cy, dx, dy in (
            (x0b, y0b, 1, 1), (x1b, y0b, -1, 1), (x0b, y1b, 1, -1), (x1b, y1b, -1, -1)
        ):
            if abs(x - cx) <= thick and min(cy, cy + dy * L) - thick <= y <= max(cy, cy + dy * L) + thick:
                return True
            if abs(y - cy) <= thick and min(cx, cx + dx * L) - thick <= x <= max(cx, cx + dx * L) + thick:
                return True
        return False

    def pixel(x, y):
        if rounded:
            dx = min(x, size - 1 - x)
            dy = min(y, size - 1 - y)
            if dx < radius and dy < radius:
                if (radius - dx) ** 2 + (radius - dy) ** 2 > radius * radius:
                    return (0, 0, 0, 0)
        t = (x + y) / (2 * (size - 1))
        r, g, b = mix(NAVY, TEAL, t)
        # soft mint glow near the lower center
        gx = (x - size * 0.5) / (size * 0.35)
        gy = (y - size * 0.62) / (size * 0.35)
        glow = max(0.0, 1 - (gx * gx + gy * gy))
        r, g, b = mix((r, g, b), MINT, glow * 0.22)
        car = inside_poly(x, y, body)
        if car:
            window = any(inside_poly(x, y, poly) for poly in windows)
            wheel = False
            hub = False
            for cx, cy, rad in wheels:
                d2 = (x - cx) ** 2 + (y - cy) ** 2
                if d2 <= (rad * 1.18) ** 2:
                    car = False
                    window = False
                if d2 <= rad * rad:
                    wheel = True
                if d2 <= (rad * 0.45) ** 2:
                    hub = True
            if window:
                r, g, b = mix(NAVY, MINT, 0.35)
            elif hub:
                r, g, b = NAVY
            elif wheel:
                r, g, b = WHITE
            elif car:
                r, g, b = WHITE
                if abs(y - sy) < size * 0.012 and margin < x < size - margin:
                    r, g, b = MINT
                elif y > sy:
                    r, g, b = mix(WHITE, MINT, 0.18)
        cx, cy, rad = size * 0.70, size * 0.33, size * 0.075
        d2 = (x - cx) ** 2 + (y - cy) ** 2
        if d2 <= rad * rad:
            r, g, b = MINT
            # simple check mark
            nx = (x - cx) / rad
            ny = (y - cy) / rad
            on_check = False
            if -0.45 <= nx <= -0.1 and abs(ny - (0.02 + (nx + 0.45) * 0.9)) < 0.12:
                on_check = True
            if -0.1 <= nx <= 0.5 and abs(ny - (0.38 - (nx + 0.1) * 1.22)) < 0.12:
                on_check = True
            if on_check:
                r, g, b = INK
        if bracket(x, y):
            r, g, b = MINT
        return (r, g, b, 255)

    return pixel


def main():
    png(ICON, 1024, 1024, render(1024, rounded=False))
    png(LOGO, 600, 600, render(600, rounded=True))
    print(ICON)
    print(LOGO)


if __name__ == "__main__":
    main()
