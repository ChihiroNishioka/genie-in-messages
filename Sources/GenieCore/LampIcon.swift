import Foundation

package enum LampAppearance: String, Sendable {
    case running
    case paused
    case warning
}

/// メニューバーと Finder 用の、丸い金色のランプ。CoreGraphics は使わない。
package enum LampIcon {
    package static func rgba(size: Int, appearance: LampAppearance) -> [UInt8] {
        render(size: size, kind: .menu(appearance))
    }

    package static func png(size: Int, appearance: LampAppearance) -> Data {
        png(size: size, rgba: rgba(size: size, appearance: appearance))
    }

    package static func appIconRGBA(size: Int) -> [UInt8] {
        render(size: size, kind: .appIcon)
    }

    package static func appIconPNG(size: Int) -> Data {
        png(size: size, rgba: appIconRGBA(size: size))
    }

    package static func appIconICNS() -> Data {
        let entries: [(String, Int)] = [("ic07", 128), ("ic08", 256), ("ic09", 512)]
        var body = Data()
        for (type, side) in entries {
            let png = appIconPNG(size: side)
            var chunk = Data(type.utf8)
            chunk.append(be32(UInt32(8 + png.count)))
            chunk.append(png)
            body.append(chunk)
        }
        var file = Data("icns".utf8)
        file.append(be32(UInt32(8 + body.count)))
        file.append(body)
        return file
    }

    private enum Kind {
        case menu(LampAppearance)
        case appIcon
    }

    private static func render(size: Int, kind: Kind) -> [UInt8] {
        let samples = size >= 256 ? 2 : 3
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let pixel = 1.0 / Double(size)
        let outline = max(1.8 / Double(size), 0.01)
        for y in 0..<size {
            for x in 0..<size {
                var red = 0.0
                var green = 0.0
                var blue = 0.0
                var alpha = 0.0
                let n = samples * samples
                for sy in 0..<samples {
                    for sx in 0..<samples {
                        let u = (Double(x) + (Double(sx) + 0.5) / Double(samples)) / Double(size)
                        let v = (Double(y) + (Double(sy) + 0.5) / Double(samples)) / Double(size)
                        let sample = shade(u: u, v: v, pixel: pixel, outline: outline, kind: kind)
                        red += sample.0
                        green += sample.1
                        blue += sample.2
                        alpha += sample.3
                    }
                }
                let i = (y * size + x) * 4
                pixels[i] = byte(red / Double(n))
                pixels[i + 1] = byte(green / Double(n))
                pixels[i + 2] = byte(blue / Double(n))
                pixels[i + 3] = byte(alpha / Double(n))
            }
        }
        return pixels
    }

    /// Straight-alpha RGBA in 0...1. y は下が正。
    private static func shade(
        u: Double,
        v: Double,
        pixel: Double,
        outline: Double,
        kind: Kind
    ) -> (Double, Double, Double, Double) {
        switch kind {
        case .appIcon:
            let bg = iconBackground(u: u, v: v, pixel: pixel)
            let lu = (u - 0.50) / 0.62 + 0.43
            let lv = (v - 0.48) / 0.62 + 0.52
            let lamp = lampPixel(u: lu, v: lv, pixel: pixel / 0.62, outline: outline / 0.62, glow: true)
            return over(lamp, bg)
        case .menu(let appearance):
            let glow = appearance != .paused
            var lamp = lampPixel(u: u, v: v, pixel: pixel, outline: outline, glow: glow)
            if appearance != .running {
                lamp = over(badge(u: u, v: v, pixel: pixel, appearance: appearance), lamp)
            }
            return lamp
        }
    }

    private static func lampPixel(
        u: Double,
        v: Double,
        pixel: Double,
        outline: Double,
        glow: Bool
    ) -> (Double, Double, Double, Double) {
        let d = lampDistance(u, v)
        let fill = cover(d + outline * 0.25, pixel)
        let body = cover(d - outline * 0.85, pixel)
        let edge = max(0, body - fill)
        let light = sat(0.35 + (0.34 - u) * 0.9 + (0.48 - v) * 1.5)
        var r = 148.0 + light * 107.0
        var g = 86.0 + light * 128.0
        var b = 16.0 + light * 64.0
        let sheen = sat(1 - hypot(u - 0.34, v - 0.50) / 0.08)
        r = min(255, r + sheen * 40)
        g = min(255, g + sheen * 30)
        b = min(255, b + sheen * 18)
        let flame = cover(ellipse(u, v, 0.86, 0.27, 0.035, 0.05), pixel * 0.8)
        r = r * (1 - flame) + 255 * flame
        g = g * (1 - flame) + 214 * flame
        b = b * (1 - flame) + 86 * flame
        let weight = fill + edge
        var lamp: (Double, Double, Double, Double) = (0, 0, 0, 0)
        if weight > 0 {
            lamp = (
                ((r / 255) * fill + (32.0 / 255) * edge) / weight,
                ((g / 255) * fill + (20.0 / 255) * edge) / weight,
                ((b / 255) * fill + (8.0 / 255) * edge) / weight,
                min(1, weight)
            )
        }
        guard glow else { return lamp }
        let gd = hypot(u - 0.87, v - 0.24)
        let halo = exp(-(gd * gd) / 0.0045) * 0.72
        return over(lamp, (1.0, 0.82, 0.28, halo))
    }

    private static func badge(
        u: Double,
        v: Double,
        pixel: Double,
        appearance: LampAppearance
    ) -> (Double, Double, Double, Double) {
        let cx = 0.80
        let cy = 0.80
        let disk = circle(u, v, cx, cy, 0.145)
        let plate = cover(disk, pixel)
        let rim = max(0, cover(disk - 0.012, pixel) - plate)
        var pixelColor = over((0.09, 0.10, 0.12, plate), (0.02, 0.02, 0.02, rim))
        switch appearance {
        case .paused:
            let barL = rounded(u, v, cx - 0.04, cy, 0.022, 0.055, 0.012)
            let barR = rounded(u, v, cx + 0.04, cy, 0.022, 0.055, 0.012)
            let bars = max(cover(barL, pixel), cover(barR, pixel))
            pixelColor = over((1, 1, 1, bars), pixelColor)
        case .warning:
            let red = cover(circle(u, v, cx, cy, 0.125), pixel)
            pixelColor = over((0.78, 0.14, 0.11, red), pixelColor)
            let stem = rounded(u, v, cx, cy - 0.02, 0.016, 0.045, 0.01)
            let dot = circle(u, v, cx, cy + 0.055, 0.018)
            let mark = max(cover(stem, pixel), cover(dot, pixel))
            pixelColor = over((1, 1, 1, mark), pixelColor)
        case .running:
            break
        }
        return pixelColor
    }

    private static func iconBackground(u: Double, v: Double, pixel: Double) -> (Double, Double, Double, Double) {
        let dx = (u - 0.5) * 2
        let dy = (v - 0.5) * 2
        let radius = pow(pow(abs(dx), 4) + pow(abs(dy), 4), 0.25)
        let inside = cover(radius - 0.94, pixel * 2)
        let t = sat(v)
        let glow = exp(-(pow(u - 0.62, 2) + pow(v - 0.40, 2)) / 0.08) * 0.22
        return (
            min(1, (46.0 * (1 - t) + 16.0 * t) / 255 + glow * 0.9),
            min(1, (72.0 * (1 - t) + 32.0 * t) / 255 + glow * 0.55),
            min(1, (128.0 * (1 - t) + 64.0 * t) / 255 + glow * 0.15),
            inside
        )
    }

    /// 負が内側。太い胴、右上への注ぎ口、左の持ち手。
    private static func lampDistance(_ x: Double, _ y: Double) -> Double {
        let body = ellipse(x, y, 0.40, 0.58, 0.23, 0.145)
        let belly = ellipse(x, y, 0.34, 0.60, 0.15, 0.125)
        let spoutA = capsule(x, y, 0.50, 0.52, 0.68, 0.40, 0.075)
        let spoutB = capsule(x, y, 0.64, 0.42, 0.82, 0.32, 0.058)
        let flare = ellipse(x, y, 0.85, 0.30, 0.055, 0.04)
        let lid = ellipse(x, y, 0.38, 0.45, 0.10, 0.042)
        let knob = circle(x, y, 0.38, 0.40, 0.03)
        let ring = abs(circle(x, y, 0.20, 0.58, 0.09)) - 0.038
        let handle = x < 0.26 ? ring : 4
        let foot = capsule(x, y, 0.28, 0.72, 0.52, 0.725, 0.026)
        return min(body, belly, spoutA, spoutB, flare, lid, knob, handle, foot)
    }

    private static func over(
        _ src: (Double, Double, Double, Double),
        _ dst: (Double, Double, Double, Double)
    ) -> (Double, Double, Double, Double) {
        let sa = src.3
        let da = dst.3
        let outA = sa + da * (1 - sa)
        guard outA > 0 else { return (0, 0, 0, 0) }
        let r = (src.0 * sa + dst.0 * da * (1 - sa)) / outA
        let g = (src.1 * sa + dst.1 * da * (1 - sa)) / outA
        let b = (src.2 * sa + dst.2 * da * (1 - sa)) / outA
        return (r, g, b, outA)
    }

    private static func ellipse(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Double {
        let dx = (x - cx) / rx
        let dy = (y - cy) / ry
        return (hypot(dx, dy) - 1) * min(rx, ry)
    }

    private static func circle(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
        hypot(x - cx, y - cy) - r
    }

    private static func capsule(
        _ x: Double,
        _ y: Double,
        _ ax: Double,
        _ ay: Double,
        _ bx: Double,
        _ by: Double,
        _ r: Double
    ) -> Double {
        let abx = bx - ax
        let aby = by - ay
        let ab2 = abx * abx + aby * aby
        var t = 0.0
        if ab2 > 0 {
            t = ((x - ax) * abx + (y - ay) * aby) / ab2
            t = min(1, max(0, t))
        }
        return hypot(ax + t * abx - x, ay + t * aby - y) - r
    }

    private static func rounded(
        _ x: Double,
        _ y: Double,
        _ cx: Double,
        _ cy: Double,
        _ hx: Double,
        _ hy: Double,
        _ radius: Double
    ) -> Double {
        let dx = abs(x - cx) - hx
        let dy = abs(y - cy) - hy
        let ax = max(dx, 0)
        let ay = max(dy, 0)
        return hypot(ax, ay) + min(max(dx, dy), 0) - radius
    }

    private static func cover(_ distance: Double, _ pixel: Double) -> Double {
        let width = max(pixel, 0.0008)
        let t = sat(0.5 - distance / width)
        return t * t * (3 - 2 * t)
    }

    private static func sat(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, Int((value * 255).rounded()))))
    }

    private static func png(size: Int, rgba: [UInt8]) -> Data {
        var raw = Data()
        raw.reserveCapacity(size * (1 + size * 4))
        for y in 0..<size {
            raw.append(0)
            let start = y * size * 4
            raw.append(contentsOf: rgba[start..<(start + size * 4)])
        }
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var ihdr = Data()
        ihdr.append(be32(UInt32(size)))
        ihdr.append(be32(UInt32(size)))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        data.append(chunk("IHDR", ihdr))
        data.append(chunk("IDAT", zlibStore(raw)))
        data.append(chunk("IEND", Data()))
        return data
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        out.append(be32(UInt32(payload.count)))
        let kind = Data(type.utf8)
        out.append(kind)
        out.append(payload)
        var crcInput = kind
        crcInput.append(payload)
        out.append(be32(crc32(crcInput)))
        return out
    }

    private static func zlibStore(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        repeat {
            let take = min(65_535, data.count - offset)
            let last = offset + take >= data.count
            out.append(last ? 1 : 0)
            let len = UInt16(take)
            out.append(UInt8(truncatingIfNeeded: len))
            out.append(UInt8(truncatingIfNeeded: len >> 8))
            let nlen = ~len
            out.append(UInt8(truncatingIfNeeded: nlen))
            out.append(UInt8(truncatingIfNeeded: nlen >> 8))
            if take > 0 {
                out.append(data.subdata(in: offset..<(offset + take)))
            }
            offset += take
        } while offset < data.count
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = (b << 16) | a
        out.append(be32(adler))
        return out
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xffff_ffff
    }
}
