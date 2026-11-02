#!/usr/bin/env python3
"""Finder アイコンの画素を、仕様の式で測る。製品スクリプトはインポートしない。"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

INNER = 824
RADIUS_N = 185
GRID = 1024

ICONSET = (
    "icon_16x16.png",
    "icon_16x16@2x.png",
    "icon_32x32.png",
    "icon_32x32@2x.png",
    "icon_128x128.png",
    "icon_128x128@2x.png",
    "icon_256x256.png",
    "icon_256x256@2x.png",
    "icon_512x512.png",
    "icon_512x512@2x.png",
)


def paeth(left: int, up: int, up_left: int) -> int:
    estimate = left + up - up_left
    best, best_d = left, abs(estimate - left)
    for value, dist in ((up, abs(estimate - up)), (up_left, abs(estimate - up_left))):
        if dist < best_d:
            best, best_d = value, dist
    return best


def read_png(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"png {path}")
    pos = 8
    width = height = color = None
    idat = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit, color = struct.unpack(">IIBB", chunk[:10])
            if bit != 8 or color not in (2, 6) or chunk[12] != 0:
                raise SystemExit(f"format {path}")
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    channels = 4 if color == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * channels
    rows: list[bytearray] = []
    index = 0
    for _ in range(height):
        filt = raw[index]
        index += 1
        row = bytearray(raw[index : index + stride])
        index += stride
        if filt == 1:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + left) & 255
        elif filt == 2:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                row[i] = (row[i] + up[i]) & 255
        elif filt == 3:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + ((left + up[i]) // 2)) & 255
        elif filt == 4:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                up_left = up[i - channels] if i >= channels else 0
                row[i] = (row[i] + paeth(left, up[i], up_left)) & 255
        elif filt != 0:
            raise SystemExit(f"filter {filt}")
        rows.append(row)
    pixels = bytearray(width * height * 4)
    for y, row in enumerate(rows):
        for x in range(width):
            src = x * channels
            dst = (y * width + x) * 4
            pixels[dst] = row[src]
            pixels[dst + 1] = row[src + 1]
            pixels[dst + 2] = row[src + 2]
            pixels[dst + 3] = row[src + 3] if channels == 4 else 255
    return width, height, bytes(pixels)


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += pixels[y * stride : (y + 1) * stride]
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(kind: bytes, body: bytes) -> bytes:
        crc = zlib.crc32(kind + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b""))


def grid(side: int) -> tuple[float, int, int]:
    inner = (side * INNER + GRID // 2) // GRID
    radius = (side * RADIUS_N + GRID // 2) // GRID
    if radius * 2 > inner:
        radius = inner // 2
    origin = (side - inner) / 2.0
    return origin, inner, radius


def coverage(distance: float) -> float:
    value = 0.5 - distance
    if value <= 0:
        return 0.0
    if value >= 1:
        return 1.0
    return value * value * (3 - 2 * value)


def signed_distance(px: float, py: float, origin: float, inner: int, radius: int) -> float:
    center = origin + inner / 2.0
    half = inner / 2.0 - radius
    dx = abs(px - center) - half
    dy = abs(py - center) - half
    outside = (max(dx, 0.0) ** 2 + max(dy, 0.0) ** 2) ** 0.5
    return outside + min(max(dx, dy), 0.0) - radius


def fit_side(side: int) -> int:
    origin, inner, radius = grid(side)
    margin = max(0.75, side * 2 / GRID)
    for n in range(inner, 0, -1):
        left = (side - n) / 2.0
        if signed_distance(left, left, origin, inner, radius) <= -margin:
            return n
    raise SystemExit(f"fit {side}")


def box_average(src: bytes, src_side: int, dst_side: int, binary: bool) -> bytes:
    if dst_side == src_side and not binary:
        return src
    out = bytearray(dst_side * dst_side * (1 if binary else 4))
    scale = src_side / dst_side
    for y in range(dst_side):
        y0 = y * scale
        y1 = (y + 1) * scale
        iy0 = int(y0)
        iy1 = min(src_side - 1, int(y1 - 1e-9))
        for x in range(dst_side):
            x0 = x * scale
            x1 = (x + 1) * scale
            ix0 = int(x0)
            ix1 = min(src_side - 1, int(x1 - 1e-9))
            acc = [0.0, 0.0, 0.0, 0.0]
            weight = 0.0
            for iy in range(iy0, iy1 + 1):
                wy = min(iy + 1, y1) - max(iy, y0)
                row = iy * src_side
                for ix in range(ix0, ix1 + 1):
                    wx = min(ix + 1, x1) - max(ix, x0)
                    w = wx * wy
                    i = (row + ix) * 4
                    if binary:
                        acc[0] += (1.0 if max(src[i], src[i + 1], src[i + 2]) > 40 else 0.0) * w
                    else:
                        acc[0] += src[i] * w
                        acc[1] += src[i + 1] * w
                        acc[2] += src[i + 2] * w
                        acc[3] += src[i + 3] * w
                    weight += w
            if binary:
                out[y * dst_side + x] = 1 if acc[0] / weight >= 0.5 else 0
            else:
                j = (y * dst_side + x) * 4
                for channel in range(4):
                    out[j + channel] = int(round(acc[channel] / weight))
    return bytes(out)


def mask_bbox(src: bytes, side: int) -> tuple[int, int, int, int]:
    min_x = min_y = side
    max_x = max_y = -1
    for y in range(side):
        row = y * side
        for x in range(side):
            i = (row + x) * 4
            if max(src[i], src[i + 1], src[i + 2]) <= 40:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if max_x < 0:
        raise SystemExit("mask empty")
    return min_x, min_y, max_x, max_y


def expected_alpha(side: int, x: int, y: int) -> int:
    origin, inner, radius = grid(side)
    samples = 4 if side <= 64 else 2
    total = 0.0
    for sy in range(samples):
        for sx in range(samples):
            px = x + (sx + 0.5) / samples
            py = y + (sy + 0.5) / samples
            total += coverage(signed_distance(px, py, origin, inner, radius))
    cover = total / (samples * samples)
    if cover <= 0:
        return 0
    if cover >= 1:
        return 255
    return int(round(255 * cover))


def sample_rgb(scaled: bytes, placed: int, left: float, x: int, y: int) -> tuple[int, int, int]:
    fx = x + 0.5 - left
    fy = y + 0.5 - left
    if fx < 0:
        ix = 0
    elif fx >= placed:
        ix = placed - 1
    else:
        ix = min(placed - 1, int(fx))
    if fy < 0:
        iy = 0
    elif fy >= placed:
        iy = placed - 1
    else:
        iy = min(placed - 1, int(fy))
    i = (iy * placed + ix) * 4
    return scaled[i], scaled[i + 1], scaled[i + 2]


def m_side_at(mask: bytes, placed: int, left: float, x: int, y: int) -> int:
    fx = x + 0.5 - left
    fy = y + 0.5 - left
    if fx < 0 or fy < 0 or fx >= placed or fy >= placed:
        return 0
    return mask[int(fy) * placed + int(fx)]


def clearance(box: tuple[int, int, int, int], side: int) -> float:
    placed = fit_side(side)
    left = (side - placed) / 2.0
    scale = placed / GRID
    x0, y0, x1, y1 = box
    corners = (
        (left + x0 * scale, left + y0 * scale),
        (left + (x1 + 1) * scale, left + y0 * scale),
        (left + x0 * scale, left + (y1 + 1) * scale),
        (left + (x1 + 1) * scale, left + (y1 + 1) * scale),
    )
    origin, inner, radius = grid(side)
    worst = max(signed_distance(px, py, origin, inner, radius) for px, py in corners)
    return -worst


def composite(pixels: bytes, side: int, background: tuple[int, int, int]) -> bytes:
    out = bytearray(side * side * 4)
    for i in range(0, len(pixels), 4):
        alpha = pixels[i + 3]
        for channel in range(3):
            value = pixels[i + channel] * alpha + background[channel] * (255 - alpha)
            out[i + channel] = int(round(value / 255))
        out[i + 3] = 255
    return bytes(out)


def nearest(pixels: bytes, side: int, scale: int) -> tuple[int, bytes]:
    out_side = side * scale
    out = bytearray(out_side * out_side * 4)
    for y in range(out_side):
        for x in range(out_side):
            src = ((y // scale) * side + (x // scale)) * 4
            dst = (y * out_side + x) * 4
            out[dst : dst + 4] = pixels[src : src + 4]
    return out_side, bytes(out)


def blit(canvas: bytearray, canvas_w: int, pixels: bytes, side: int, left: int, top: int) -> None:
    for y in range(side):
        src = y * side * 4
        dst = ((top + y) * canvas_w + left) * 4
        canvas[dst : dst + side * 4] = pixels[src : src + side * 4]


def write_finder_sheet(root: Path, directory: Path) -> None:
    before_512 = read_png(root / "Tests/GenieCoreTests/Fixtures/finder-before-512.png")[2]
    after_512 = read_png(root / "AppBundle/AppIcon.iconset/icon_512x512.png")[2]
    before_32 = read_png(root / "Tests/GenieCoreTests/Fixtures/finder-before-32.png")[2]
    after_32 = read_png(root / "AppBundle/AppIcon.iconset/icon_32x32.png")[2]
    gray = (180, 180, 180)
    top_before = composite(before_512, 512, gray)
    top_after = composite(after_512, 512, gray)
    small = 32 * 8
    bot_before = nearest(composite(before_32, 32, gray), 32, 8)[1]
    bot_after = nearest(composite(after_32, 32, gray), 32, 8)[1]
    gap = 16
    width = gap + 512 + gap + 512 + gap
    height = gap + 512 + gap + small + gap
    canvas = bytearray(width * height * 4)
    for i in range(0, len(canvas), 4):
        canvas[i : i + 4] = bytes((32, 32, 34, 255))
    blit(canvas, width, top_before, 512, gap, gap)
    blit(canvas, width, top_after, 512, gap + 512 + gap, gap)
    top = gap + 512 + gap
    blit(canvas, width, bot_before, small, gap, top)
    blit(canvas, width, bot_after, small, gap + 512 + gap, top)
    directory.mkdir(parents=True, exist_ok=True)
    write_png(directory / "finder-before-after.png", width, height, bytes(canvas))


def measure(root: Path) -> dict[str, int]:
    master_path = root / "AppBundle/FinderLamp-1024.png"
    if not master_path.is_file():
        raise SystemExit("master missing")
    side, height, master = read_png(master_path)
    if side != 1024 or height != 1024:
        raise SystemExit("master size")
    opaque = 0
    for i in range(3, len(master), 4):
        if master[i] != 255:
            opaque += 1
    mask_path = root / "Tests/GenieCoreTests/Fixtures/finder-content-mask-1024.png"
    mask_w, mask_h, mask_src = read_png(mask_path)
    if mask_w != 1024 or mask_h != 1024:
        raise SystemExit("mask size")
    box = mask_bbox(mask_src, 1024)
    src_w = box[2] - box[0] + 1
    src_h = box[3] - box[1] + 1
    counts = {
        "master_alpha": opaque,
        "alpha_mismatch": 0,
        "interior_not_black": 0,
        "purple": 0,
        "fringe_not_black": 0,
        "mask_alpha": 0,
        "bbox_over": 0,
        "rgb_over": 0,
        "clearance_below": 0,
    }
    worst = None
    icon_dir = root / "AppBundle/AppIcon.iconset"
    for name in ICONSET:
        file_side, file_h, pixels = read_png(icon_dir / name)
        if file_side != file_h:
            raise SystemExit(name)
        side = file_side
        origin, inner, radius = grid(side)
        placed = fit_side(side)
        left = (side - placed) / 2.0
        scaled = box_average(master, 1024, placed, False)
        mask = box_average(mask_src, 1024, placed, True)
        bits = [0] * (side * side)
        dilated = bytearray(side * side)
        min_x = min_y = side
        max_x = max_y = -1
        for y in range(side):
            for x in range(side):
                bit = m_side_at(mask, placed, left, x, y)
                if not bit:
                    continue
                bits[y * side + x] = 1
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
                for dy in (-1, 0, 1):
                    ny = y + dy
                    if ny < 0 or ny >= side:
                        continue
                    row = ny * side
                    for dx in (-1, 0, 1):
                        nx = x + dx
                        if 0 <= nx < side:
                            dilated[row + nx] = 1
        mask_points = max_x >= 0
        for y in range(side):
            for x in range(side):
                bit = bits[y * side + x]
                d = signed_distance(x + 0.5, y + 0.5, origin, inner, radius)
                i = (y * side + x) * 4
                red, green, blue, alpha = pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]
                expect = expected_alpha(side, x, y)
                if alpha != expect:
                    counts["alpha_mismatch"] += 1
                if bit == 0 and d <= -1 and not dilated[y * side + x]:
                    if (red, green, blue, alpha) != (0, 0, 0, 255):
                        counts["interior_not_black"] += 1
                if d <= 0 and bit == 0 and blue > red + 10 and blue > green and blue > 40:
                    counts["purple"] += 1
                if -1 < d <= 0.5 and (red, green, blue) != (0, 0, 0):
                    counts["fringe_not_black"] += 1
                if bit:
                    if alpha != 255:
                        counts["mask_alpha"] += 1
                    er, eg, eb = sample_rgb(scaled, placed, left, x, y)
                    if max(abs(red - er), abs(green - eg), abs(blue - eb)) > 2:
                        counts["rgb_over"] += 1
        if mask_points:
            actual_w = max_x - min_x + 1
            actual_h = max_y - min_y + 1
            expect_w = src_w * placed / 1024
            expect_h = src_h * placed / 1024
            if abs(actual_w - expect_w) > 1 or abs(actual_h - expect_h) > 1:
                counts["bbox_over"] += 1
        gap = clearance(box, side)
        if gap <= 0.5:
            counts["clearance_below"] += 1
        if worst is None or gap < worst:
            worst = gap
    counts["clearance_milli"] = int(round((worst or 0) * 1000))
    return counts


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    shots = None
    if "--screenshots" in sys.argv:
        shots = Path(sys.argv[sys.argv.index("--screenshots") + 1])
    counts = measure(root)
    if shots is not None:
        write_finder_sheet(root, shots)
        made = shots / "finder-before-after.png"
        if not made.is_file() or made.stat().st_size < 1000:
            raise SystemExit("screenshot")
    for key, value in counts.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
