#!/usr/bin/env python3
"""メニューバー用の白黒 template を、原本から抜いて線を太らせる。

入力は AppBundle/GenieLampV2-1024.png。残すのはランプ本体と、注ぎ口より上の
右寄りの雲。色は黒だけで、縁のぼかしは使わない。高さは 18pt。幅は絵の自然な
幅で、@2x と @3x はその整数倍。引き伸ばさない。

通常は雲、一時停止は縦棒2本、要対応は「!」。ランプ本体は3状態で同じ画素。
承認した型は AppBundle/MenuLamp/reference/ に書く。

使い方: scripts/make-menu-icon.py
"""

from __future__ import annotations

import struct
import zlib
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AppBundle" / "GenieLampV2-1024.png"
OUT_DIR = ROOT / "AppBundle" / "MenuLamp"
REFERENCE = OUT_DIR / "reference"
SIDE = 1024
CLOSE_RADIUS = 6
GROW_RADIUS = 48
SMOKE_GROW = 18
SMOKE_LEFT_OF_SPOUT = 0.30
SMOKE_VALUE = 0.48
POINT = 18


def read_rgb(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"PNG ではありません: {path}")
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
            raise SystemExit(f"未知のフィルタ {filt}: {path}")
        rows.append(row)
    rgb = bytearray(width * height * 3)
    for y, row in enumerate(rows):
        for x in range(width):
            src = x * channels
            dst = (y * width + x) * 3
            rgb[dst : dst + 3] = row[src : src + 3]
    return width, height, bytes(rgb)


def paeth(left: int, up: int, up_left: int) -> int:
    estimate = left + up - up_left
    best, best_d = left, abs(estimate - left)
    for value, dist in ((up, abs(estimate - up)), (up_left, abs(estimate - up_left))):
        if dist < best_d:
            best, best_d = value, dist
    return best


def zlib_store(data: bytes) -> bytes:
    """LampIcon が libz なしで読める、非圧縮の zlib。"""
    out = bytearray([0x78, 0x01])
    offset = 0
    while True:
        take = min(65535, len(data) - offset)
        last = offset + take >= len(data)
        out.append(1 if last else 0)
        out += struct.pack("<HH", take, (~take) & 0xFFFF)
        out += data[offset : offset + take]
        offset += take
        if last:
            break
    a = 1
    b = 0
    for byte in data:
        a = (a + byte) % 65521
        b = (b + a) % 65521
    out += struct.pack(">I", (b << 16) | a)
    return bytes(out)


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += pixels[y * stride : (y + 1) * stride]
    payload = zlib_store(bytes(raw))

    def chunk(kind: bytes, body: bytes) -> bytes:
        crc = zlib.crc32(kind + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", payload) + chunk(b"IEND", b""))


def hsv(red: int, green: int, blue: int) -> tuple[float, float, float]:
    rf, gf, bf = red / 255, green / 255, blue / 255
    peak = max(rf, gf, bf)
    floor = min(rf, gf, bf)
    delta = peak - floor
    if delta == 0:
        hue = 0.0
    elif peak == rf:
        hue = ((gf - bf) / delta) % 6
    elif peak == gf:
        hue = (bf - rf) / delta + 2
    else:
        hue = (rf - gf) / delta + 4
    saturation = 0.0 if peak == 0 else delta / peak
    return hue * 60, saturation, peak


def is_gold(red: int, green: int, blue: int) -> bool:
    hue, saturation, value = hsv(red, green, blue)
    if not (8 <= hue <= 72 and red > blue + 8 and red >= 48):
        return False
    if saturation >= 0.18 and value >= 0.15:
        return True
    return saturation >= 0.06 and value >= 0.70


def is_blue(red: int, green: int, blue: int) -> bool:
    return blue > red and blue > green


def lamp_mask(rgb: bytes) -> bytearray:
    gold = bytearray(SIDE * SIDE)
    for index in range(SIDE * SIDE):
        offset = index * 3
        if is_gold(rgb[offset], rgb[offset + 1], rgb[offset + 2]):
            gold[index] = 1
    seen = bytearray(SIDE * SIDE)
    queue = [x for x in range(SIDE)]
    queue += [(SIDE - 1) * SIDE + x for x in range(SIDE)]
    queue += [y * SIDE for y in range(SIDE)]
    queue += [y * SIDE + SIDE - 1 for y in range(SIDE)]
    head = 0
    while head < len(queue):
        index = queue[head]
        head += 1
        if index < 0 or index >= SIDE * SIDE or seen[index] or gold[index]:
            continue
        seen[index] = 1
        x = index % SIDE
        if x + 1 < SIDE:
            queue.append(index + 1)
        if x > 0:
            queue.append(index - 1)
        if index + SIDE < SIDE * SIDE:
            queue.append(index + SIDE)
        if index - SIDE >= 0:
            queue.append(index - SIDE)
    mask = bytearray(gold)
    for index in range(SIDE * SIDE):
        if gold[index] or seen[index]:
            continue
        offset = index * 3
        if is_blue(rgb[offset], rgb[offset + 1], rgb[offset + 2]):
            continue
        mask[index] = 1
    return mask


def spout_and_bounds(mask: bytearray) -> tuple[int, int, int, int, int, int]:
    min_x, min_y = SIDE, SIDE
    max_x = max_y = -1
    for y in range(SIDE):
        row = y * SIDE
        for x in range(SIDE):
            if not mask[row + x]:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    spout_x = spout_y = -1
    for y in range(SIDE):
        row = y * SIDE
        for x in range(SIDE - 1, -1, -1):
            if mask[row + x]:
                if x > spout_x or (x == spout_x and (spout_y < 0 or y < spout_y)):
                    spout_x, spout_y = x, y
                break
    if spout_x < 0:
        raise SystemExit("ランプが見つかりません")
    return min_x, min_y, max_x, max_y, spout_x, spout_y


def morph_close(mask: bytearray, radius: int) -> bytearray:
    dil = bytearray(SIDE * SIDE)
    for y in range(SIDE):
        for x in range(SIDE):
            if not mask[y * SIDE + x]:
                continue
            y0, y1 = max(0, y - radius), min(SIDE, y + radius + 1)
            x0, x1 = max(0, x - radius), min(SIDE, x + radius + 1)
            span = b"\x01" * (x1 - x0)
            for yy in range(y0, y1):
                dil[yy * SIDE + x0 : yy * SIDE + x1] = span
    out = bytearray(SIDE * SIDE)
    for y in range(SIDE):
        for x in range(SIDE):
            y0, y1 = max(0, y - radius), min(SIDE, y + radius + 1)
            x0, x1 = max(0, x - radius), min(SIDE, x + radius + 1)
            ok = 1
            for yy in range(y0, y1):
                row = yy * SIDE
                if any(dil[row + xx] == 0 for xx in range(x0, x1)):
                    ok = 0
                    break
            out[y * SIDE + x] = ok
    return out


def enclosed_hole(mask: bytearray) -> bytearray:
    seen = bytearray(SIDE * SIDE)
    queue = deque()
    for x in range(SIDE):
        queue.append(x)
        queue.append((SIDE - 1) * SIDE + x)
    for y in range(SIDE):
        queue.append(y * SIDE)
        queue.append(y * SIDE + SIDE - 1)
    while queue:
        index = queue.popleft()
        if index < 0 or index >= SIDE * SIDE or seen[index] or mask[index]:
            continue
        seen[index] = 1
        x = index % SIDE
        if x + 1 < SIDE:
            queue.append(index + 1)
        if x:
            queue.append(index - 1)
        if index + SIDE < SIDE * SIDE:
            queue.append(index + SIDE)
        if index - SIDE >= 0:
            queue.append(index - SIDE)
    hole = bytearray(SIDE * SIDE)
    for index in range(SIDE * SIDE):
        if not mask[index] and not seen[index]:
            hole[index] = 1
    return hole


def grow(mask: bytearray, avoid: bytearray, radius: int) -> bytearray:
    dist = bytearray(SIDE * SIDE)
    queue = deque()
    for index, bit in enumerate(mask):
        if bit:
            dist[index] = 1
            queue.append(index)
    while queue:
        index = queue.popleft()
        step = dist[index]
        if step > radius:
            continue
        x = index % SIDE
        y = index // SIDE
        nxt = step + 1
        for yy in range(max(0, y - 1), min(SIDE, y + 2)):
            row = yy * SIDE
            for xx in range(max(0, x - 1), min(SIDE, x + 2)):
                neighbor = row + xx
                if dist[neighbor] or avoid[neighbor]:
                    continue
                dist[neighbor] = nxt
                queue.append(neighbor)
    out = bytearray(SIDE * SIDE)
    for index, step in enumerate(dist):
        if step and not avoid[index]:
            out[index] = 1
    return out


def smoke_mask(rgb: bytes, lamp: bytearray, spout_x: int, spout_y: int, min_x: int) -> bytearray:
    window_left = spout_x - int(round((spout_x - min_x) * SMOKE_LEFT_OF_SPOUT))
    smoke = bytearray(SIDE * SIDE)
    for y in range(spout_y + 1):
        row = y * SIDE
        for x in range(window_left, SIDE):
            index = row + x
            if lamp[index]:
                continue
            offset = index * 3
            red, green, blue = rgb[offset], rgb[offset + 1], rgb[offset + 2]
            _hue, _saturation, value = hsv(red, green, blue)
            if value >= SMOKE_VALUE and blue >= green:
                smoke[index] = 1
    return grow(smoke, lamp, SMOKE_GROW)


def picture_bounds(*masks: bytearray) -> tuple[int, int, int, int]:
    min_x, min_y = SIDE, SIDE
    max_x = max_y = -1
    for mask in masks:
        for index, bit in enumerate(mask):
            if not bit:
                continue
            x, y = index % SIDE, index // SIDE
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    return min_x, min_y, max_x, max_y


def downsample(mask: bytearray, bounds: tuple[int, int, int, int], height: int) -> list[list[int]]:
    bx0, by0, bx1, by1 = bounds
    src_w, src_h = bx1 - bx0 + 1, by1 - by0 + 1
    width = max(1, int(round(src_w * height / src_h)))
    grid = [[0] * width for _ in range(height)]
    for y in range(height):
        sy0 = by0 + y * src_h / height
        sy1 = by0 + (y + 1) * src_h / height
        iy0 = int(sy0)
        iy1 = min(by1, int(sy1 - 1e-9))
        for x in range(width):
            sx0 = bx0 + x * src_w / width
            sx1 = bx0 + (x + 1) * src_w / width
            ix0 = int(sx0)
            ix1 = min(bx1, int(sx1 - 1e-9))
            acc = 0.0
            area = 0.0
            for iy in range(iy0, iy1 + 1):
                wy = min(iy + 1, sy1) - max(iy, sy0)
                row = iy * SIDE
                for ix in range(ix0, ix1 + 1):
                    wx = min(ix + 1, sx1) - max(ix, sx0)
                    acc += mask[row + ix] * wx * wy
                    area += wx * wy
            grid[y][x] = 1 if area and acc / area >= 0.45 else 0
    return grid


def scale_grid(grid: list[list[int]], factor: int) -> list[list[int]]:
    height, width = len(grid), len(grid[0])
    out = [[0] * (width * factor) for _ in range(height * factor)]
    for y in range(height):
        for x in range(width):
            if not grid[y][x]:
                continue
            for dy in range(factor):
                for dx in range(factor):
                    out[y * factor + dy][x * factor + dx] = 1
    return out


def to_png(grid: list[list[int]]) -> bytes:
    height, width = len(grid), len(grid[0])
    pixels = bytearray(width * height * 4)
    for y, row in enumerate(grid):
        for x, bit in enumerate(row):
            if bit:
                pixels[(y * width + x) * 4 + 3] = 255
    return bytes(pixels)


def dist_to(points: list[tuple[int, int]], x: int, y: int) -> int:
    return min(max(abs(x - px), abs(y - py)) for px, py in points)


def frame_cells(grid: list[list[int]]) -> set[tuple[int, int]]:
    height, width = len(grid), len(grid[0])
    lamp = [(x, y) for y in range(height) for x in range(width) if grid[y][x]]
    xs = [p[0] for p in lamp]
    center = (min(xs) + max(xs)) / 2
    spout_x = spout_y = -1
    for x in range(width - 1, -1, -1):
        column = [y for y in range(height) if grid[y][x]]
        if column:
            spout_x, spout_y = x, min(column)
            break
    cells = set()
    for y in range(spout_y):
        for x in range(int(center) + 1, width):
            if grid[y][x]:
                continue
            if dist_to(lamp, x, y) >= 2:
                cells.add((x, y))
    _ = spout_x
    return cells


def open_cloud(smoke: list[list[int]], frame: set[tuple[int, int]]) -> list[tuple[int, int]]:
    height, width = len(smoke), len(smoke[0])
    raw = [[1 if (x, y) in frame and smoke[y][x] else 0 for x in range(width)] for y in range(height)]
    opened = [[0] * width for _ in range(height)]
    for y in range(height - 1):
        for x in range(width - 1):
            if raw[y][x] and raw[y][x + 1] and raw[y + 1][x] and raw[y + 1][x + 1]:
                opened[y][x] = opened[y][x + 1] = opened[y + 1][x] = opened[y + 1][x + 1] = 1
    return [(x, y) for y in range(height) for x in range(width) if opened[y][x]]


def pause_bars(frame: set[tuple[int, int]], width: int) -> list[tuple[int, int]]:
    chosen: tuple[int, int] | None = None
    for left in range(width):
        right = left + 3
        if right + 1 >= width:
            continue
        cells = [(x, y) for y in range(6) for x in (left, left + 1, right, right + 1)]
        if all(cell in frame for cell in cells):
            chosen = (left, right)
    if chosen is None:
        raise SystemExit("一時停止の縦棒が記号枠に入りません")
    left, right = chosen
    return [(x, y) for y in range(6) for x in (left, left + 1, right, right + 1)]


def warning_mark(frame: set[tuple[int, int]], width: int) -> list[tuple[int, int]]:
    placed = None
    for x in range(width - 2, 0, -1):
        if all((x, y) in frame and (x + 1, y) in frame for y in range(7)):
            placed = x
            break
    if placed is None:
        raise SystemExit("要対応の記号が記号枠に入りません")
    stem = [(placed, y) for y in range(4)] + [(placed + 1, y) for y in range(4)]
    dot = [(placed, y) for y in range(5, 7)] + [(placed + 1, y) for y in range(5, 7)]
    return stem + dot


def stamp(base: list[list[int]], extra: list[tuple[int, int]]) -> list[list[int]]:
    grid = [row[:] for row in base]
    for x, y in extra:
        grid[y][x] = 1
    return grid


def main() -> None:
    side, height, rgb = read_rgb(SOURCE)
    if side != SIDE or height != SIDE:
        raise SystemExit(f"1024px の原本が必要です（実際は {side}x{height}）")
    mask = lamp_mask(rgb)
    closed = morph_close(mask, CLOSE_RADIUS)
    hole = enclosed_hole(closed)
    if sum(hole) == 0:
        raise SystemExit("取っ手の穴が閉じません")
    thick = grow(closed, hole, GROW_RADIUS)
    min_x, min_y, max_x, max_y, spout_x, spout_y = spout_and_bounds(mask)
    smoke = smoke_mask(rgb, mask, spout_x, spout_y, min_x)
    bounds = picture_bounds(thick, smoke)
    lamp = downsample(thick, bounds, POINT)
    cloud = open_cloud(downsample(smoke, bounds, POINT), frame_cells(lamp))
    if len(cloud) < 4:
        raise SystemExit("雲が足りません")
    states = {
        "lamp": stamp(lamp, cloud),
        "lamp-paused": stamp(lamp, pause_bars(frame_cells(lamp), len(lamp[0]))),
        "lamp-warning": stamp(lamp, warning_mark(frame_cells(lamp), len(lamp[0]))),
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    REFERENCE.mkdir(parents=True, exist_ok=True)
    for scale in (1, 2, 3):
        for name, grid in states.items():
            scaled = scale_grid(grid, scale)
            path = OUT_DIR / f"{name}@{scale}x.png"
            write_png(path, len(scaled[0]), len(scaled), to_png(scaled))
            print(f"wrote {path.name} {len(scaled[0])}x{len(scaled)}")
        reference = scale_grid(lamp, scale)
        path = REFERENCE / f"lamp@{scale}x.png"
        write_png(path, len(reference[0]), len(reference), to_png(reference))
        print(f"wrote reference/{path.name} {len(reference[0])}x{len(reference)}")


if __name__ == "__main__":
    main()
