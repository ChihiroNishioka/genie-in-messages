#!/usr/bin/env python3
"""メニューバー用の透過ランプを、Finder と同じ原本から作る。

入力は AppBundle/GenieLampV2-1024.png。残すのは金色のランプ本体と、
注ぎ口より上かつ右寄りの明るい雲だけ。ランプの左・下・周囲の紫は透過にする。
透過の余白は詰め、高さ 18pt いっぱいに縮める。template 画像にはしない。

使い方: scripts/make-menu-icon.py
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AppBundle" / "GenieLampV2-1024.png"
OUT_DIR = ROOT / "AppBundle" / "MenuLamp"
SCALES = (1, 2, 3)
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
    best = left
    best_d = abs(estimate - left)
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


# 注ぎ口から、ランプ幅のこの割合だけ左までを雲の範囲にする。それより左は残さない。
SMOKE_LEFT_OF_SPOUT = 0.30
# この明度より明るい画素だけを雲にする。紺のグラデーションはここまで明るくない。
SMOKE_VALUE = 0.48
# 18pt でも筋が残るよう、原本画素で少し広げる。
SMOKE_DILATE = 22


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
    """ランプ本体。金色は色相と彩度で見る。ハイライトは彩度が低くても残す。"""
    hue, saturation, value = hsv(red, green, blue)
    if not (8 <= hue <= 72 and red > blue + 8 and red >= 48):
        return False
    if saturation >= 0.18 and value >= 0.15:
        return True
    return saturation >= 0.06 and value >= 0.70


def is_blue(red: int, green: int, blue: int) -> bool:
    return blue > red and blue > green


def lamp_mask(rgb: bytes, side: int) -> bytearray:
    """金色と、その内側のハイライト。外につながる紺の穴（取っ手の中）は入れない。"""
    gold = bytearray(side * side)
    for index in range(side * side):
        offset = index * 3
        if is_gold(rgb[offset], rgb[offset + 1], rgb[offset + 2]):
            gold[index] = 1
    seen = bytearray(side * side)
    queue = [x for x in range(side)]
    queue += [(side - 1) * side + x for x in range(side)]
    queue += [y * side for y in range(side)]
    queue += [y * side + side - 1 for y in range(side)]
    head = 0
    while head < len(queue):
        index = queue[head]
        head += 1
        if index < 0 or index >= side * side or seen[index] or gold[index]:
            continue
        seen[index] = 1
        x = index % side
        if x + 1 < side:
            queue.append(index + 1)
        if x > 0:
            queue.append(index - 1)
        if index + side < side * side:
            queue.append(index + side)
        if index - side >= 0:
            queue.append(index - side)
    mask = bytearray(gold)
    for index in range(side * side):
        if gold[index] or seen[index]:
            continue
        offset = index * 3
        if is_blue(rgb[offset], rgb[offset + 1], rgb[offset + 2]):
            continue
        mask[index] = 1
    return mask


def spout_and_bounds(mask: bytearray, side: int) -> tuple[int, int, int, int, int, int]:
    min_x, min_y = side, side
    max_x = max_y = -1
    for y in range(side):
        row = y * side
        for x in range(side):
            if not mask[row + x]:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    spout_x = spout_y = -1
    for y in range(side):
        row = y * side
        for x in range(side - 1, -1, -1):
            if mask[row + x]:
                if x > spout_x or (x == spout_x and (spout_y < 0 or y < spout_y)):
                    spout_x, spout_y = x, y
                break
    if spout_x < 0:
        raise SystemExit("ランプが見つかりません")
    return min_x, min_y, max_x, max_y, spout_x, spout_y


def smoke_color(red: int, green: int, blue: int, fringe: bool) -> tuple[int, int, int, int]:
    """小さいサイズでも筋が見えるよう、明るい紫に寄せる。"""
    out_red = min(255, int(red * 0.40 + 168))
    out_green = min(255, int(green * 0.30 + 112))
    out_blue = min(255, int(blue * 0.35 + 196))
    if out_blue < out_green + 24:
        out_blue = min(255, out_green + 36)
    return out_red, out_green, out_blue, 200 if fringe else 255


def cut_out(rgb: bytes, side: int) -> tuple[bytes, int, int]:
    mask = lamp_mask(rgb, side)
    min_x, min_y, max_x, max_y, spout_x, spout_y = spout_and_bounds(mask, side)
    window_left = spout_x - int(round((spout_x - min_x) * SMOKE_LEFT_OF_SPOUT))
    seeds: list[int] = []
    for y in range(spout_y + 1):
        row = y * side
        for x in range(window_left, side):
            index = row + x
            if mask[index]:
                continue
            offset = index * 3
            red, green, blue = rgb[offset], rgb[offset + 1], rgb[offset + 2]
            _hue, _saturation, value = hsv(red, green, blue)
            if value >= SMOKE_VALUE and blue >= green:
                seeds.append(index)
    smoke = bytearray(side * side)
    distance = bytearray(side * side)
    queue = list(seeds)
    for index in seeds:
        smoke[index] = 1
    head = 0
    while head < len(queue):
        index = queue[head]
        head += 1
        current = distance[index]
        if current >= SMOKE_DILATE:
            continue
        x = index % side
        y = index // side
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if nx < window_left or ny < 0 or ny > spout_y or nx >= side:
                continue
            neighbor = ny * side + nx
            if smoke[neighbor] or mask[neighbor]:
                continue
            smoke[neighbor] = 1
            distance[neighbor] = current + 1
            queue.append(neighbor)
    pixels = bytearray(side * side * 4)
    for index in range(side * side):
        offset = index * 3
        red, green, blue = rgb[offset], rgb[offset + 1], rgb[offset + 2]
        if mask[index]:
            pixels[index * 4 : index * 4 + 4] = bytes((red, green, blue, 255))
        elif smoke[index]:
            pixels[index * 4 : index * 4 + 4] = bytes(smoke_color(red, green, blue, distance[index] > 0))
    print(
        f"lamp=({min_x},{min_y})-({max_x},{max_y}) spout=({spout_x},{spout_y}) "
        f"smoke_x>={window_left} seeds={len(seeds)}"
    )
    return bytes(pixels), side, side


def opaque_bounds(pixels: bytes, width: int, height: int) -> tuple[int, int, int, int]:
    min_x, min_y = width, height
    max_x = max_y = -1
    for y in range(height):
        row = y * width * 4
        for x in range(width):
            if pixels[row + x * 4 + 3] == 0:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if max_x < 0:
        raise SystemExit("透過にした結果、絵が残りません")
    return min_x, min_y, max_x, max_y


def crop(pixels: bytes, width: int, height: int) -> tuple[bytes, int, int]:
    min_x, min_y, max_x, max_y = opaque_bounds(pixels, width, height)
    out_w = max_x - min_x + 1
    out_h = max_y - min_y + 1
    out = bytearray(out_w * out_h * 4)
    for y in range(out_h):
        src = ((min_y + y) * width + min_x) * 4
        dst = y * out_w * 4
        out[dst : dst + out_w * 4] = pixels[src : src + out_w * 4]
    return bytes(out), out_w, out_h


def box_down(pixels: bytes, src_w: int, src_h: int, dst_w: int, dst_h: int) -> bytes:
    """前乗算してから平均し、縁が背景色で濁らないようにする。"""
    premul = bytearray(len(pixels))
    for i in range(0, len(pixels), 4):
        alpha = pixels[i + 3]
        if alpha == 0:
            continue
        premul[i] = pixels[i] * alpha // 255
        premul[i + 1] = pixels[i + 1] * alpha // 255
        premul[i + 2] = pixels[i + 2] * alpha // 255
        premul[i + 3] = alpha
    out = bytearray(dst_w * dst_h * 4)
    scale_x = src_w / dst_w
    scale_y = src_h / dst_h
    for y in range(dst_h):
        y0 = y * scale_y
        y1 = (y + 1) * scale_y
        iy0 = int(y0)
        iy1 = min(src_h - 1, int(y1 - 1e-9))
        for x in range(dst_w):
            x0 = x * scale_x
            x1 = (x + 1) * scale_x
            ix0 = int(x0)
            ix1 = min(src_w - 1, int(x1 - 1e-9))
            acc = [0.0, 0.0, 0.0, 0.0]
            weight = 0.0
            for iy in range(iy0, iy1 + 1):
                wy = min(iy + 1, y1) - max(iy, y0)
                for ix in range(ix0, ix1 + 1):
                    wx = min(ix + 1, x1) - max(ix, x0)
                    area = wx * wy
                    source = (iy * src_w + ix) * 4
                    for channel in range(4):
                        acc[channel] += premul[source + channel] * area
                    weight += area
            alpha = acc[3] / weight
            dest = (y * dst_w + x) * 4
            if alpha < 1:
                continue
            if alpha >= 254.5:
                for channel in range(3):
                    out[dest + channel] = int(round(acc[channel] / weight))
                out[dest + 3] = 255
                continue
            for channel in range(3):
                out[dest + channel] = int(round(acc[channel] / weight * 255 / alpha))
            out[dest + 3] = int(round(alpha))
    return bytes(out)


def main() -> None:
    side, height, rgb = read_rgb(SOURCE)
    if side != 1024 or height != 1024:
        raise SystemExit(f"1024px の原本が必要です（実際は {side}x{height}）")
    cut, cut_w, cut_h = cut_out(rgb, side)
    cropped, src_w, src_h = crop(cut, cut_w, cut_h)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for scale in SCALES:
        dst_h = POINT * scale
        dst_w = max(1, int(round(src_w * dst_h / src_h)))
        pixels = box_down(cropped, src_w, src_h, dst_w, dst_h)
        path = OUT_DIR / f"lamp@{scale}x.png"
        write_png(path, dst_w, dst_h, pixels)
        print(f"wrote {path} {dst_w}x{dst_h} from {src_w}x{src_h}")


if __name__ == "__main__":
    main()
