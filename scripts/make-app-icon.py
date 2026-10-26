#!/usr/bin/env python3
"""Finder 用 AppIcon.icns を、金色ランプの iconset から作る。

入力は AppBundle/GoldenLamp.iconset の10枚。どれも RGBA だが、角まで不透明な正方形。
macOS のアイコングリッド（1024 で内側 824、角半径 185 の角丸矩形。他のサイズは同じ比率）
の外を透明にして、AppBundle/AppIcon.iconset と AppBundle/AppIcon.icns を書く。

各サイズは、そのサイズの素材をその場で切り抜く。1024 から縮小しない（小さいランプがつぶれないように）。
メニューバーのランプはここでは作らない。コードで描いたまま。

使い方: scripts/make-app-icon.py
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AppBundle" / "GoldenLamp.iconset"
MASKED = ROOT / "AppBundle" / "AppIcon.iconset"
ICNS_PATH = ROOT / "AppBundle" / "AppIcon.icns"

# 1024 キャンバスの内側 824、角半径 185。端数は四捨五入。
INNER_NUMERATOR = 824
RADIUS_NUMERATOR = 185
GRID = 1024

# icns の並び。同じ辺でも 16@2x と 32 は別の絵なので、両方残す。
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
    idat = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit, color = struct.unpack(">IIBB", chunk[:10])
            if bit != 8 or color != 6:
                raise SystemExit(f"RGBA 8bit だけを読めます: {path}")
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    if width is None or height is None:
        raise SystemExit(f"IHDR がありません: {path}")
    raw = zlib.decompress(idat)
    stride = width * 4
    rows: list[bytearray] = []
    index = 0
    for _ in range(height):
        filt = raw[index]
        index += 1
        row = bytearray(raw[index : index + stride])
        index += stride
        if filt == 0:
            pass
        elif filt == 1:
            for i in range(stride):
                left = row[i - 4] if i >= 4 else 0
                row[i] = (row[i] + left) & 0xFF
        elif filt == 2:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                row[i] = (row[i] + up[i]) & 0xFF
        elif filt == 3:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                left = row[i - 4] if i >= 4 else 0
                row[i] = (row[i] + ((left + up[i]) // 2)) & 0xFF
        elif filt == 4:
            up = rows[-1] if rows else bytearray(stride)
            for i in range(stride):
                left = row[i - 4] if i >= 4 else 0
                up_left = up[i - 4] if i >= 4 else 0
                row[i] = (row[i] + paeth(left, up[i], up_left)) & 0xFF
        else:
            raise SystemExit(f"未知のフィルタ {filt}: {path}")
        rows.append(row)
    pixels = bytearray()
    for row in rows:
        pixels += row
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
    # 境界の前後 0.5px を滑らかにする。負が内側。
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


def mask(pixels: bytearray, side: int) -> bytes:
    origin, inner, radius = grid(side)
    samples = 4 if side <= 64 else 2
    out = bytearray(len(pixels))
    for y in range(side):
        for x in range(side):
            total = 0.0
            for sy in range(samples):
                for sx in range(samples):
                    px = x + (sx + 0.5) / samples
                    py = y + (sy + 0.5) / samples
                    total += coverage(signed_distance(px, py, origin, inner, radius))
            cover = total / (samples * samples)
            i = (y * side + x) * 4
            if cover <= 0:
                continue
            if cover >= 1:
                out[i : i + 4] = pixels[i : i + 4]
                continue
            alpha = int(round(pixels[i + 3] * cover))
            if alpha <= 0:
                continue
            out[i] = pixels[i]
            out[i + 1] = pixels[i + 1]
            out[i + 2] = pixels[i + 2]
            out[i + 3] = alpha
    return bytes(out)


def pack_icns(entries: list[tuple[str, bytes]]) -> bytes:
    body = b""
    for kind, png in entries:
        body += kind.encode("ascii") + struct.pack(">I", 8 + len(png)) + png
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def main() -> None:
    MASKED.mkdir(parents=True, exist_ok=True)
    written: dict[str, bytes] = {}
    for path in sorted(SOURCE.glob("icon_*.png")):
        width, height, pixels = read_png(path)
        if width != height:
            raise SystemExit(f"正方形ではありません: {path}")
        masked = mask(pixels, width)
        destination = MASKED / path.name
        write_png(destination, width, height, masked)
        written[path.name] = destination.read_bytes()
    icns_parts: list[tuple[str, bytes]] = []
    for kind, name, side in ICNS_ENTRIES:
        png = written[name]
        width, height, _ = read_png(MASKED / name)
        if width != side or height != side:
            raise SystemExit(f"{name} は {side}px である必要があります（実際は {width}）")
        icns_parts.append((kind, png))
    ICNS_PATH.write_bytes(pack_icns(icns_parts))
    print(f"wrote {MASKED} and {ICNS_PATH} ({ICNS_PATH.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
