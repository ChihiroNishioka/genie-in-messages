import Foundation

package enum LampAppearance: String, Sendable {
    case running
    case paused
    case warning
}

/// メニューバー用のランプ。原本は `scripts/make-menu-icon.py` が抜いた透過 PNG。
/// 一時停止と要対応の印だけ、この画像の上に重ねる。template 画像にはしない。
package enum LampIcon {
    package static let menuPointSize = 18
    package static let menuScales = [1, 2, 3]
    package static let menuImageIsTemplate = false

    package static func rgba(pixelSize: Int, appearance: LampAppearance) -> [UInt8] {
        var pixels = basePixels(pixelSize: pixelSize)
        guard appearance != .running else { return pixels }
        let pixel = 1.0 / Double(pixelSize)
        for y in 0..<pixelSize {
            for x in 0..<pixelSize {
                let u = (Double(x) + 0.5) / Double(pixelSize)
                let v = (Double(y) + 0.5) / Double(pixelSize)
                let mark = badge(u: u, v: v, pixel: pixel, appearance: appearance)
                let index = (y * pixelSize + x) * 4
                let under = (
                    Double(pixels[index]) / 255,
                    Double(pixels[index + 1]) / 255,
                    Double(pixels[index + 2]) / 255,
                    Double(pixels[index + 3]) / 255
                )
                let over = over(mark, under)
                pixels[index] = byte(over.0)
                pixels[index + 1] = byte(over.1)
                pixels[index + 2] = byte(over.2)
                pixels[index + 3] = byte(over.3)
            }
        }
        return pixels
    }

    package static func png(pixelSize: Int, appearance: LampAppearance) -> Data {
        encodePNG(size: pixelSize, rgba: rgba(pixelSize: pixelSize, appearance: appearance))
    }

    /// メニューバー風の下地の上に載せ、必要なら最近傍で拡大する。
    package static func flattenedPNG(
        pixelSize: Int,
        appearance: LampAppearance,
        background: (UInt8, UInt8, UInt8),
        magnification: Int = 1
    ) -> Data {
        let source = rgba(pixelSize: pixelSize, appearance: appearance)
        let flat = flatten(source, size: pixelSize, background: background)
        let scale = max(1, magnification)
        let sized = scale == 1 ? flat : nearest(flat, size: pixelSize, scale: scale)
        return encodePNG(size: pixelSize * scale, rgba: sized)
    }

    package static func menuLampURL(pixelSize: Int) -> URL {
        let name = "lamp@\(pixelSize / menuPointSize)x"
        if let bundled = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MenuLamp"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AppBundle/MenuLamp/\(name).png")
    }

    private static let cacheLock = NSLock()
    private static var cache: [Int: [UInt8]] = [:]

    private static func basePixels(pixelSize: Int) -> [UInt8] {
        cacheLock.lock()
        if let hit = cache[pixelSize] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let loaded = decodeStoredPNG(menuLampURL(pixelSize: pixelSize))
        cacheLock.lock()
        cache[pixelSize] = loaded
        cacheLock.unlock()
        return loaded
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

    private static func over(
        _ src: (Double, Double, Double, Double),
        _ dst: (Double, Double, Double, Double)
    ) -> (Double, Double, Double, Double) {
        let sourceAlpha = src.3
        let destAlpha = dst.3
        let outAlpha = sourceAlpha + destAlpha * (1 - sourceAlpha)
        guard outAlpha > 0 else { return (0, 0, 0, 0) }
        return (
            (src.0 * sourceAlpha + dst.0 * destAlpha * (1 - sourceAlpha)) / outAlpha,
            (src.1 * sourceAlpha + dst.1 * destAlpha * (1 - sourceAlpha)) / outAlpha,
            (src.2 * sourceAlpha + dst.2 * destAlpha * (1 - sourceAlpha)) / outAlpha,
            outAlpha
        )
    }

    private static func circle(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
        hypot(x - cx, y - cy) - r
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
        return hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius
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

    private static func flatten(_ pixels: [UInt8], size: Int, background: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: pixels.count)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            out[index] = UInt8((Int(pixels[index]) * alpha + Int(background.0) * (255 - alpha)) / 255)
            out[index + 1] = UInt8((Int(pixels[index + 1]) * alpha + Int(background.1) * (255 - alpha)) / 255)
            out[index + 2] = UInt8((Int(pixels[index + 2]) * alpha + Int(background.2) * (255 - alpha)) / 255)
        }
        _ = size
        return out
    }

    private static func nearest(_ pixels: [UInt8], size: Int, scale: Int) -> [UInt8] {
        let side = size * scale
        var out = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let from = ((y / scale) * size + (x / scale)) * 4
                let to = (y * side + x) * 4
                out[to] = pixels[from]
                out[to + 1] = pixels[from + 1]
                out[to + 2] = pixels[from + 2]
                out[to + 3] = pixels[from + 3]
            }
        }
        return out
    }

    private static func encodePNG(size: Int, rgba: [UInt8]) -> Data {
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

    private static func decodeStoredPNG(_ url: URL) -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return []
        }
        guard data.count > 8, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return [] }
        var offset = 8
        var width = 0
        var height = 0
        var idat = Data()
        while offset + 8 <= data.count {
            let length = Int(be32(data, offset))
            let kind = String(data: data.subdata(in: (offset + 4)..<(offset + 8)), encoding: .ascii) ?? ""
            let start = offset + 8
            let end = start + length
            guard end + 4 <= data.count else { return [] }
            let payload = data.subdata(in: start..<end)
            if kind == "IHDR", payload.count >= 10 {
                width = Int(be32(payload, 0))
                height = Int(be32(payload, 4))
            } else if kind == "IDAT" {
                idat.append(payload)
            } else if kind == "IEND" {
                break
            }
            offset = end + 4
        }
        guard width > 0, height > 0, let inflated = inflateStored(idat) else { return [] }
        let stride = width * 4
        guard inflated.count >= height * (1 + stride) else { return [] }
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        var cursor = 0
        for _ in 0..<height {
            guard inflated[cursor] == 0 else { return [] }
            cursor += 1
            pixels.append(contentsOf: inflated[cursor..<(cursor + stride)])
            cursor += stride
        }
        return pixels
    }

    /// zlib の非圧縮ブロック。`make-menu-icon.py` が同じ形で書く。
    private static func inflateStored(_ data: Data) -> Data? {
        guard data.count >= 2, data[data.startIndex] == 0x78 else { return nil }
        var index = 2
        var out = Data()
        while index < data.count {
            let last = data[data.startIndex + index] == 1
            index += 1
            guard index + 4 <= data.count else { return nil }
            let len = Int(data[data.startIndex + index]) | (Int(data[data.startIndex + index + 1]) << 8)
            index += 4
            guard index + len <= data.count else { return nil }
            out.append(data.subdata(in: (data.startIndex + index)..<(data.startIndex + index + len)))
            index += len
            if last { break }
        }
        return out
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
        out.append(be32((b << 16) | a))
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

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<(start + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
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
