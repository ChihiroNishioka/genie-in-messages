import Foundation
#if canImport(AppKit)
import AppKit
#endif

package enum LampAppearance: String, Sendable {
    case running
    case paused
    case warning

    /// メニューバーのランプを要対応にするか。照合で止まっているときも含む。
    package static func showsAttention(_ snap: EngineSnapshot) -> Bool {
        snap.screenLock != .unlocked
            || snap.heldLockCount > 0
            || !snap.haltedChatIDs.isEmpty
            || snap.lastError == "watch_start_failed"
            || snap.holdNotice != nil
    }
}

/// メニューバー用のランプ。原本は `scripts/make-menu-icon.py` が抜いた白黒の template。
/// 高さは 18pt。幅は絵の自然な幅で、倍率はその整数倍。状態は雲・縦棒・「!」の形で描き分ける。
package enum LampIcon {
    package static let menuPointSize = 18
    package static let menuScales = [1, 2, 3]
    package static let menuImageIsTemplate = true
    package static let approvedMenuWidths = [1: 21, 2: 42, 3: 63]
    /// メニュー画像の置き場所。通常は AppBundle/MenuLamp。
    package static var menuLampRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("AppBundle/MenuLamp")
    /// 画像が無いときの記録先。アプリが起動時にセットする。
    package static var menuLampLogger: (any GenieLog)?

    package static func appearance(for snapshot: EngineSnapshot?) -> LampAppearance {
        guard let snapshot else { return .running }
        if LampAppearance.showsAttention(snapshot) { return .warning }
        if snapshot.paused { return .paused }
        return .running
    }

    package static func statusLabel(for appearance: LampAppearance) -> String {
        switch appearance {
        case .running: return "ジーニー 監視中"
        case .paused: return "ジーニー 一時停止"
        case .warning: return "ジーニー 要確認"
        }
    }

    package static func rgba(pixelHeight: Int, appearance: LampAppearance) -> (width: Int, height: Int, pixels: [UInt8]) {
        baseRaster(pixelHeight: pixelHeight, appearance: appearance)
    }

    package static func png(pixelHeight: Int, appearance: LampAppearance) -> Data {
        let raster = rgba(pixelHeight: pixelHeight, appearance: appearance)
        return encodePNG(width: raster.width, height: raster.height, rgba: raster.pixels)
    }

    package static func menuLampURL(pixelHeight: Int, appearance: LampAppearance) -> URL {
        let scale = max(pixelHeight, 1) / menuPointSize
        let stem: String
        switch appearance {
        case .running: stem = "lamp"
        case .paused: stem = "lamp-paused"
        case .warning: stem = "lamp-warning"
        }
        let name = "\(stem)@\(scale)x"
        if let bundled = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MenuLamp"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return menuLampRoot.appendingPathComponent("\(name).png")
    }

    #if canImport(AppKit)
    package static func menuImage(for appearance: LampAppearance) -> NSImage {
        let point = CGFloat(menuPointSize)
        let image = NSImage()
        var size = NSSize(width: point, height: point)
        for scale in menuScales {
            let raster = rgba(pixelHeight: menuPointSize * scale, appearance: appearance)
            guard raster.height > 0, let rep = NSBitmapImageRep(data: png(pixelHeight: menuPointSize * scale, appearance: appearance)) else {
                continue
            }
            let width = point * CGFloat(raster.width) / CGFloat(raster.height)
            rep.size = NSSize(width: width, height: point)
            image.addRepresentation(rep)
            size = rep.size
        }
        image.size = size
        image.isTemplate = menuImageIsTemplate
        return image
    }

    package static func applyStatus(to button: NSButton, snapshot: EngineSnapshot?) {
        let state = appearance(for: snapshot)
        let image = menuImage(for: state)
        image.isTemplate = menuImageIsTemplate
        button.image = image
        let label = statusLabel(for: state)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    package enum MenuBarStatus {
        package static func apply(to button: NSButton, snapshot: EngineSnapshot?) {
            LampIcon.applyStatus(to: button, snapshot: snapshot)
            button.imagePosition = .imageOnly
        }
    }
    #endif

    private static let cacheLock = NSLock()
    private static var cache: [String: (width: Int, height: Int, pixels: [UInt8])] = [:]

    private static func baseRaster(pixelHeight: Int, appearance: LampAppearance) -> (width: Int, height: Int, pixels: [UInt8]) {
        let key = "\(menuLampRoot.path)|\(pixelHeight)|\(appearance.rawValue)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let loaded = decodeStoredPNG(menuLampURL(pixelHeight: pixelHeight, appearance: appearance))
        cacheLock.lock()
        cache[key] = loaded
        cacheLock.unlock()
        return loaded
    }

    private static func encodePNG(width: Int, height: Int, rgba: [UInt8]) -> Data {
        var raw = Data()
        raw.reserveCapacity(height * (1 + width * 4))
        for y in 0..<height {
            raw.append(0)
            let start = y * width * 4
            raw.append(contentsOf: rgba[start..<(start + width * 4)])
        }
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var ihdr = Data()
        ihdr.append(be32(UInt32(width)))
        ihdr.append(be32(UInt32(height)))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        data.append(chunk("IHDR", ihdr))
        data.append(chunk("IDAT", zlibStore(raw)))
        data.append(chunk("IEND", Data()))
        return data
    }

    private static func decodeStoredPNG(_ url: URL) -> (width: Int, height: Int, pixels: [UInt8]) {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return (0, 0, [])
        }
        guard data.count > 8, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return (0, 0, []) }
        var offset = 8
        var width = 0
        var height = 0
        var idat = Data()
        while offset + 8 <= data.count {
            let length = Int(be32(data, offset))
            let kind = String(data: data.subdata(in: (offset + 4)..<(offset + 8)), encoding: .ascii) ?? ""
            let start = offset + 8
            let end = start + length
            guard end + 4 <= data.count else { return (0, 0, []) }
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
        guard width > 0, height > 0, let inflated = inflateStored(idat) else { return (0, 0, []) }
        let stride = width * 4
        guard inflated.count >= height * (1 + stride) else { return (0, 0, []) }
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        var cursor = 0
        for _ in 0..<height {
            guard inflated[cursor] == 0 else { return (0, 0, []) }
            cursor += 1
            pixels.append(contentsOf: inflated[cursor..<(cursor + stride)])
            cursor += stride
        }
        return (width, height, pixels)
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
