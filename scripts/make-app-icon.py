#!/usr/bin/env python3
"""Finder 用 AppIcon.icns を、1枚のランプ画像から作る。

入力は AppBundle/GenieLampV2-1024.png。ランプは金色のまま、雲は紫にならない
薄い色にして、それ以外の背景は黒にする。角丸の外は透明。縁の色は黒だけで、
透明度だけが変わる。

各サイズは原本から直接縮小する。メニューバーのランプはここでは作らない。

使い方:
  scripts/make-app-icon.py            # iconset と icns を書く
  scripts/make-app-icon.py --check-fit  # 取っ手・フタ・雲の範囲が角丸の内側か
"""

from __future__ import annotations

import importlib.util
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AppBundle" / "GenieLampV2-1024.png"
MASTER = ROOT / "AppBundle" / "FinderLamp-1024.png"
MASKED = ROOT / "AppBundle" / "AppIcon.iconset"
ICNS_PATH = ROOT / "AppBundle" / "AppIcon.icns"

INNER_NUMERATOR = 824
RADIUS_NUMERATOR = 185
GRID = 1024

ICONSET = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)

ICNS_ENTRIES = (
    ("icp4", "icon_16x16.png", 16),
    ("icp5", "icon_32x32.png", 32),
    ("ic11", "icon_16x16@2x.png", 32),
    ("ic12", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128),
    ("ic08", "icon_256x256.png", 256),
    ("ic09", "icon_512x512.png", 512),
    ("ic10", "icon_512x512@2x.png", 1024),
)


def read_png(path: Path) -> tuple[int, int, bytearray]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"PNG ではありません: {path}")
    pos = 8
    width = height = None
    color = None
    idat = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit, color = struct.unpack(">IIBB", chunk[:10])
            interlace = chunk[12]
            if bit != 8 or color not in (2, 6) or interlace != 0:
                raise SystemExit(f"8bit の RGB か RGBA だけを読めます: {path}")
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    if width is None or height is None or color is None:
        raise SystemExit(f"IHDR がありません: {path}")
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
                row[i] = (row[i] + left) & 0xFF
        elif filt == 2:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                row[i] = (row[i] + up[i]) & 0xFF
        elif filt == 3:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + ((left + up[i]) // 2)) & 0xFF
        elif filt == 4:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                up_left = up[i - channels] if i >= channels else 0
                row[i] = (row[i] + paeth(left, up[i], up_left)) & 0xFF
        elif filt != 0:
            raise SystemExit(f"未知のフィルタ {filt}: {path}")
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
    return width, height, pixels


def paeth(left: int, up: int, up_left: int) -> int:
    estimate = left + up - up_left
    dl = abs(estimate - left)
    du = abs(estimate - up)
    dul = abs(estimate - up_left)
    if dl <= du and dl <= dul:
        return left
    if du <= dul:
        return up
    return up_left


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += pixels[y * stride : (y + 1) * stride]
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        crc = zlib.crc32(kind + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b"")
    path.write_bytes(data)


def grid(side: int) -> tuple[float, int, int]:
    inner = (side * INNER_NUMERATOR + GRID // 2) // GRID
    radius = (side * RADIUS_NUMERATOR + GRID // 2) // GRID
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
    """角丸の内側に、端が欠けずに収まる正方形の一辺。"""
    origin, inner, radius = grid(side)
    margin = max(0.75, side * 2 / GRID)
    for n in range(inner, 0, -1):
        left = (side - n) / 2.0
        if signed_distance(left, left, origin, inner, radius) <= -margin:
            return n
    raise SystemExit(f"{side}px の角丸に絵が収まりません")


def box_resize(src: bytes, src_side: int, dst_side: int) -> bytes:
    if dst_side == src_side:
        return bytes(src)
    out = bytearray(dst_side * dst_side * 4)
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
                    acc[0] += src[i] * w
                    acc[1] += src[i + 1] * w
                    acc[2] += src[i + 2] * w
                    acc[3] += src[i + 3] * w
                    weight += w
            j = (y * dst_side + x) * 4
            for channel in range(4):
                out[j + channel] = int(round(acc[channel] / weight))
    return bytes(out)


def mask_at(mask: bytes, placed: int, left: float, x: int, y: int) -> int:
    """範囲の外は 0。中は 0.5 以上を 1 にしたマスク。"""
    fx = x + 0.5 - left
    fy = y + 0.5 - left
    if fx < 0 or fy < 0 or fx >= placed or fy >= placed:
        return 0
    return mask[int(fy) * placed + int(fx)]


def binary_mask(src: bytes, src_side: int, placed: int) -> bytes:
    out = bytearray(placed * placed)
    scale = src_side / placed
    for y in range(placed):
        y0 = y * scale
        y1 = (y + 1) * scale
        iy0 = int(y0)
        iy1 = min(src_side - 1, int(y1 - 1e-9))
        for x in range(placed):
            x0 = x * scale
            x1 = (x + 1) * scale
            ix0 = int(x0)
            ix1 = min(src_side - 1, int(x1 - 1e-9))
            acc = 0.0
            weight = 0.0
            for iy in range(iy0, iy1 + 1):
                wy = min(iy + 1, y1) - max(iy, y0)
                row = iy * src_side
                for ix in range(ix0, ix1 + 1):
                    wx = min(ix + 1, x1) - max(ix, x0)
                    w = wx * wy
                    i = (row + ix) * 4
                    if max(src[i], src[i + 1], src[i + 2]) > 40:
                        acc += w
                    weight += w
            out[y * placed + x] = 1 if weight and acc / weight >= 0.5 else 0
    return bytes(out)


def render(src: bytes, src_side: int, side: int) -> bytes:
    placed = fit_side(side)
    scaled = box_resize(src, src_side, placed)
    mask = binary_mask(src, src_side, placed)
    origin, inner, radius = grid(side)
    left = (side - placed) / 2.0
    samples = 4 if side <= 64 else 2
    out = bytearray(side * side * 4)
    for y in range(side):
        for x in range(side):
            total = 0.0
            for sy in range(samples):
                for sx in range(samples):
                    px = x + (sx + 0.5) / samples
                    py = y + (sy + 0.5) / samples
                    total += coverage(signed_distance(px, py, origin, inner, radius))
            cover = total / (samples * samples)
            if cover <= 0:
                continue
            dst_i = (y * side + x) * 4
            alpha = 255 if cover >= 1 else int(round(255 * cover))
            if not mask_at(mask, placed, left, x, y):
                out[dst_i + 3] = alpha
                continue
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
            src_i = (iy * placed + ix) * 4
            out[dst_i] = scaled[src_i]
            out[dst_i + 1] = scaled[src_i + 1]
            out[dst_i + 2] = scaled[src_i + 2]
            out[dst_i + 3] = alpha
    return bytes(out)


def content_bbox(pixels: bytes, side: int) -> tuple[int, int, int, int]:
    """ランプのマスク。max(R,G,B) > 40 の画素。"""
    min_x, min_y, max_x, max_y = side, side, -1, -1
    for y in range(side):
        for x in range(side):
            i = (y * side + x) * 4
            if max(pixels[i], pixels[i + 1], pixels[i + 2]) <= 40:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if max_x < 0:
        raise SystemExit("背景と違う画素がありません")
    return min_x, min_y, max_x, max_y


def clearance(
    pixels: bytes,
    src_side: int,
    side: int,
    box: tuple[int, int, int, int] | None = None,
) -> tuple[int, tuple[int, int, int, int], float, float]:
    """戻り値は、置いた一辺、原本の範囲、内容の内側余裕、絵の四隅の距離。距離は負が内側。"""
    placed = fit_side(side)
    if box is None:
        box = content_bbox(pixels, src_side)
    left = (side - placed) / 2.0
    scale = placed / src_side
    x0, y0, x1, y1 = box
    corners = (
        (left + x0 * scale, left + y0 * scale),
        (left + (x1 + 1) * scale, left + y0 * scale),
        (left + x0 * scale, left + (y1 + 1) * scale),
        (left + (x1 + 1) * scale, left + (y1 + 1) * scale),
    )
    origin, inner, radius = grid(side)
    # 四隅のうち一番外側の角。負が内側なので、最大の符号付き距離が一番厳しい。
    content_distance = max(signed_distance(px, py, origin, inner, radius) for px, py in corners)
    image_corner = signed_distance(left, left, origin, inner, radius)
    return placed, box, -content_distance, image_corner


def report(pixels: bytes, src_side: int) -> str:
    lines = []
    worst = None
    box = content_bbox(pixels, src_side)
    seen: set[int] = set()
    for _, side in ICONSET:
        placed, box, content_clearance, image_corner = clearance(pixels, src_side, side, box)
        if content_clearance <= 0.5 or image_corner > -0.5:
            raise SystemExit(
                f"{side}px で絵が角丸からはみ出します "
                f"clearance={content_clearance:.2f} image_corner={image_corner:.2f}"
            )
        if worst is None or content_clearance < worst:
            worst = content_clearance
        if side in seen:
            continue
        seen.add(side)
        x0, y0, x1, y1 = box
        lines.append(
            f"side={side} placed={placed} "
            f"content={x0},{y0}-{x1},{y1} "
            f"clearance={content_clearance:.2f} "
            f"image_corner={image_corner:.2f}"
        )
    lines.append(f"clearance_px={worst:.2f}")
    return "\n".join(lines)


def pack_icns(entries: list[tuple[str, bytes]]) -> bytes:
    body = b""
    for kind, png in entries:
        body += kind.encode("ascii") + struct.pack(">I", 8 + len(png)) + png
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def load_menu():
    spec = importlib.util.spec_from_file_location("menu_icon", Path(__file__).with_name("make-menu-icon.py"))
    module = importlib.util.module_from_spec(spec)
    if spec.loader is None:
        raise SystemExit("メニューのスクリプトを読めません")
    spec.loader.exec_module(module)
    return module


def finder_master(menu) -> bytes:
    """金色のランプと、紫にしない雲。背景は黒。"""
    side, height, rgb = menu.read_rgb(SOURCE)
    if side != 1024 or height != 1024:
        raise SystemExit(f"1024px の原本が必要です（実際は {side}x{height}）")
    mask = menu.lamp_mask(rgb)
    min_x, _min_y, _max_x, _max_y, spout_x, spout_y = menu.spout_and_bounds(mask)
    window_left = spout_x - int(round((spout_x - min_x) * menu.SMOKE_LEFT_OF_SPOUT))
    pixels = bytearray(side * side * 4)
    for index in range(side * side):
        offset = index * 3
        red, green, blue = rgb[offset], rgb[offset + 1], rgb[offset + 2]
        x, y = index % side, index // side
        if mask[index]:
            out = (red, green, blue)
            if max(out) <= 40:
                out = (41, 28, 8)
        elif y <= spout_y and x >= window_left:
            _hue, _sat, value = menu.hsv(red, green, blue)
            peak = max(red, green, blue)
            if value >= menu.SMOKE_VALUE and blue >= green and peak > 40:
                out = (peak, min(255, int(peak * 0.92)), min(255, int(peak * 0.75)))
            else:
                out = (0, 0, 0)
        else:
            out = (0, 0, 0)
        dst = index * 4
        pixels[dst] = out[0]
        pixels[dst + 1] = out[1]
        pixels[dst + 2] = out[2]
        pixels[dst + 3] = 255
    return thicken_content(bytes(pixels), 8)


def thicken_content(pixels: bytes, radius: int) -> bytes:
    """縁を少し太らせ、縮小しても外接矩形が欠けないようにする。"""
    side = 1024
    seeds = bytearray(side * side)
    for index in range(side * side):
        offset = index * 4
        if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > 40:
            seeds[index] = 1
    dist = bytearray(side * side)
    color = bytearray(side * side * 3)
    from collections import deque

    queue: deque[int] = deque()
    for index, bit in enumerate(seeds):
        if not bit:
            continue
        dist[index] = 1
        offset = index * 4
        color[index * 3 : index * 3 + 3] = pixels[offset : offset + 3]
        queue.append(index)
    while queue:
        index = queue.popleft()
        step = dist[index]
        if step > radius:
            continue
        x = index % side
        y = index // side
        nxt = step + 1
        base = index * 3
        for yy in range(max(0, y - 1), min(side, y + 2)):
            row = yy * side
            for xx in range(max(0, x - 1), min(side, x + 2)):
                neighbor = row + xx
                if dist[neighbor]:
                    continue
                dist[neighbor] = nxt
                color[neighbor * 3 : neighbor * 3 + 3] = color[base : base + 3]
                queue.append(neighbor)
    out = bytearray(pixels)
    for index, step in enumerate(dist):
        if not step:
            continue
        offset = index * 4
        out[offset : offset + 3] = color[index * 3 : index * 3 + 3]
        out[offset + 3] = 255
    return bytes(out)


def main() -> None:
    menu = load_menu()
    pixels = finder_master(menu)
    width = 1024
    text = report(pixels, width)
    if "--check-fit" in sys.argv:
        print(text)
        return
    MASKED.mkdir(parents=True, exist_ok=True)
    write_png(MASTER, width, width, pixels)
    written: dict[str, bytes] = {}
    src = pixels
    for name, side in ICONSET:
        rendered = render(src, width, side)
        destination = MASKED / name
        write_png(destination, side, side, rendered)
        written[name] = destination.read_bytes()
    parts = [(kind, written[name]) for kind, name, _ in ICNS_ENTRIES]
    ICNS_PATH.write_bytes(pack_icns(parts))
    print(text)
    print(f"wrote {MASKED} and {ICNS_PATH} ({ICNS_PATH.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
