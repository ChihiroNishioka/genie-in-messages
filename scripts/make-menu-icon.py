#!/usr/bin/env python3
"""メニューバー用の透過ランプを、Finder と同じ原本から作る。

入力は AppBundle/GenieLampV2-1024.png。背景の紺を抜き、ランプと紫の雲だけを残す。
縁の紺が残らないよう、画素を背景色との差で抜き、混ざった色からは紺を引く。
出力は高さ 18pt の @1x/@2x/@3x（18/36/54px）。template 画像にはしない。

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


def background(rgb: bytes, side: int, x: int, y: int) -> tuple[float, float, float]:
    # 左右の縁は紺だけなので、その行の左右を混ぜて下地にする。
    left = (y * side + 2) * 3
    right = (y * side + (side - 3)) * 3
    tx = x / (side - 1)
    return tuple((1 - tx) * rgb[left + c] + tx * rgb[right + c] for c in range(3))


def smooth(distance: float) -> float:
    t = (distance - 32) / (78 - 32)
    if t <= 0:
        return 0.0
    if t >= 1:
        return 1.0
    return t * t * (3 - 2 * t)


def key_pixel(color: tuple[int, int, int], bg: tuple[float, float, float]) -> tuple[int, int, int, int]:
    distance = sum(abs(color[i] - bg[i]) for i in range(3))
    alpha = smooth(distance)
    if alpha <= 0.02:
        return (0, 0, 0, 0)
    if alpha >= 0.985:
        fg = [float(channel) for channel in color]
    else:
        fg = []
        for i in range(3):
            value = (color[i] - bg[i] * (1 - alpha)) / alpha
            fg.append(min(255.0, max(0.0, value)))
    red, green, blue = fg
    luma = 0.30 * red + 0.59 * green + 0.11 * blue
    blueish = blue >= red - 5 and blue >= green - 5 and red < 120 and green < 100
    if blueish and luma < 42:
        return (0, 0, 0, 0)
    # 小さいサイズでも雲が残るよう、紫を少し濃くする。
    if blue > green and blue > 80 and 35 < red < blue + 50 and green < blue and luma < 210:
        alpha = min(1.0, alpha * 1.35 + 0.25)
        fg = [
            min(255.0, red * 0.72 + 62),
            min(255.0, green * 0.62 + 42),
            min(255.0, blue * 0.80 + 55),
        ]
    out_alpha = 255 if alpha >= 0.99 else int(round(alpha * 255))
    return tuple(int(round(channel)) for channel in fg) + (out_alpha,)


def cut_out(rgb: bytes, side: int) -> bytes:
    pixels = bytearray(side * side * 4)
    for y in range(side):
        for x in range(side):
            i = (y * side + x) * 3
            color = (rgb[i], rgb[i + 1], rgb[i + 2])
            pixels[(y * side + x) * 4 : (y * side + x) * 4 + 4] = bytes(key_pixel(color, background(rgb, side, x, y)))
    return bytes(pixels)


def box_down(pixels: bytes, src: int, dst: int) -> bytes:
    """前乗算してから平均し、縁が紺で濁らないようにする。"""
    premul = bytearray(len(pixels))
    for i in range(0, len(pixels), 4):
        alpha = pixels[i + 3]
        if alpha == 0:
            continue
        premul[i] = pixels[i] * alpha // 255
        premul[i + 1] = pixels[i + 1] * alpha // 255
        premul[i + 2] = pixels[i + 2] * alpha // 255
        premul[i + 3] = alpha
    out = bytearray(dst * dst * 4)
    scale = src / dst
    for y in range(dst):
        y0 = y * scale
        y1 = (y + 1) * scale
        iy0 = int(y0)
        iy1 = min(src - 1, int(y1 - 1e-9))
        for x in range(dst):
            x0 = x * scale
            x1 = (x + 1) * scale
            ix0 = int(x0)
            ix1 = min(src - 1, int(x1 - 1e-9))
            acc = [0.0, 0.0, 0.0, 0.0]
            weight = 0.0
            for iy in range(iy0, iy1 + 1):
                wy = min(iy + 1, y1) - max(iy, y0)
                for ix in range(ix0, ix1 + 1):
                    wx = min(ix + 1, x1) - max(ix, x0)
                    w = wx * wy
                    s = (iy * src + ix) * 4
                    for channel in range(4):
                        acc[channel] += premul[s + channel] * w
                    weight += w
            alpha = acc[3] / weight
            j = (y * dst + x) * 4
            if alpha < 1:
                continue
            if alpha >= 254.5:
                for channel in range(3):
                    out[j + channel] = int(round(acc[channel] / weight))
                out[j + 3] = 255
                continue
            for channel in range(3):
                out[j + channel] = int(round(acc[channel] / weight * 255 / alpha))
            out[j + 3] = int(round(alpha))
    return bytes(out)


def main() -> None:
    side, _, rgb = read_rgb(SOURCE)
    if side != 1024:
        raise SystemExit(f"1024px の原本が必要です（実際は {side}）")
    cut = cut_out(rgb, side)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for scale in SCALES:
        pixels = box_down(cut, side, POINT * scale)
        path = OUT_DIR / f"lamp@{scale}x.png"
        write_png(path, POINT * scale, POINT * scale, pixels)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
