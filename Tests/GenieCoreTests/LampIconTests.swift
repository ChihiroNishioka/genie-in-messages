import XCTest
@testable import GenieCore
#if canImport(AppKit)
import AppKit
#endif

final class LampIconTests: XCTestCase {
    func testMenuLampFilesAreTransparentAndNotTemplates() throws {
        XCTAssertFalse(LampIcon.menuImageIsTemplate)
        XCTAssertEqual(LampIcon.menuPointSize, 18)
        XCTAssertEqual(LampIcon.menuScales, [1, 2, 3])
        let root = repoRoot()
        let assemble = try String(contentsOf: root.appendingPathComponent("scripts/assemble-app.sh"), encoding: .utf8)
        XCTAssertTrue(assemble.contains("Contents/Resources/MenuLamp"))
        let app = try String(contentsOf: root.appendingPathComponent("Sources/GenieMenuBar/GenieMenuBarApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("isTemplate = LampIcon.menuImageIsTemplate"))
        XCTAssertTrue(app.contains("LampIcon.menuPointSize"))
        for scale in LampIcon.menuScales {
            let height = LampIcon.menuPointSize * scale
            let name = "lamp@\(scale)x.png"
            XCTAssertTrue(assemble.contains(name))
            let url = LampIcon.menuLampURL(pixelHeight: height)
            XCTAssertTrue(url.path.hasSuffix("AppBundle/MenuLamp/\(name)"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let raster = LampIcon.rgba(pixelHeight: height, appearance: .running)
            XCTAssertEqual(raster.height, height, name)
            XCTAssertGreaterThan(raster.width, raster.height / 2, name)
            XCTAssertEqual(raster.pixels.count, raster.width * raster.height * 4, name)
            XCTAssertEqual(cornerAlphas(raster.pixels, width: raster.width, height: raster.height), [0, 0, 0, 0], name)
            XCTAssertEqual(navyFringe(raster.pixels), 0, name)
            XCTAssertGreaterThan(smokeCount(raster.pixels), scale == 1 ? 12 : 60, name)
            XCTAssertGreaterThan(goldCount(raster.pixels), scale == 1 ? 8 : 40, name)
            let box = opaqueBounds(raster.pixels, width: raster.width, height: raster.height)
            XCTAssertLessThanOrEqual(box.minY, 1, name)
            XCTAssertGreaterThanOrEqual(box.maxY, raster.height - 2, name)
        }
    }

    /// ランプの外、左と下には紫も不透明な画素も残さない。雲は注ぎ口より上にある。
    func testNoPurpleLeftOfOrBelowTheLamp() {
        let image = LampIcon.rgba(pixelHeight: 54, appearance: .running)
        let lamp = goldBounds(image.pixels, width: image.width, height: image.height)
        XCTAssertLessThanOrEqual(lamp.minX, 1)
        XCTAssertGreaterThanOrEqual(lamp.maxY, image.height - 2)
        XCTAssertGreaterThan(lamp.maxX, lamp.minX)
        var stray = 0
        var purpleAbove = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                let pixel = Pixel(
                    r: image.pixels[index],
                    g: image.pixels[index + 1],
                    b: image.pixels[index + 2],
                    a: image.pixels[index + 3]
                )
                let outside = x < lamp.minX || y > lamp.maxY
                if outside && pixel.a > 20 {
                    stray += 1
                }
                if y < lamp.minY && isPurple(pixel) {
                    purpleAbove += 1
                }
            }
        }
        XCTAssertEqual(stray, 0)
        XCTAssertGreaterThan(purpleAbove, 20)
    }

    func testStatesDifferAndReadOnLightAndDark() {
        let running = LampIcon.rgba(pixelHeight: 54, appearance: .running)
        let paused = LampIcon.rgba(pixelHeight: 54, appearance: .paused)
        let warning = LampIcon.rgba(pixelHeight: 54, appearance: .warning)
        XCTAssertNotEqual(running.pixels, paused.pixels)
        XCTAssertNotEqual(running.pixels, warning.pixels)
        XCTAssertNotEqual(paused.pixels, warning.pixels)
        XCTAssertGreaterThan(goldCount(running.pixels), 40)
        XCTAssertGreaterThan(smokeCount(running.pixels), 60)
        XCTAssertGreaterThan(whiteCount(paused.pixels), whiteCount(running.pixels))
        XCTAssertGreaterThan(redCount(warning.pixels), redCount(running.pixels))
        XCTAssertGreaterThan(redCount(warning.pixels), 8)
        for raster in [running, paused, warning] {
            XCTAssertEqual(cornerAlphas(raster.pixels, width: raster.width, height: raster.height), [0, 0, 0, 0])
            XCTAssertGreaterThan(contrast(raster.pixels, background: (244, 244, 246)), 30)
            XCTAssertGreaterThan(contrast(raster.pixels, background: (28, 28, 30)), 30)
        }
        let bounds = opaqueBounds(running.pixels, width: running.width, height: running.height)
        XCTAssertGreaterThan(bounds.maxX - bounds.minX, running.width / 2)
        XCTAssertGreaterThan(bounds.maxY - bounds.minY, running.height / 2)
    }

    func testMenuPngHeader() {
        let png = LampIcon.png(pixelHeight: 18, appearance: .running)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    /// 同梱 PNG はスクリプトを再実行しても変わらない。
    func testMenuLampMatchesTheScript() throws {
        let root = repoRoot()
        let files = LampIcon.menuScales.map {
            root.appendingPathComponent("AppBundle/MenuLamp/lamp@\($0)x.png")
        }
        let before = try files.map { try Data(contentsOf: $0) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/make-menu-icon.py").path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, err + text)
        let after = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(after, before)
    }

    #if canImport(AppKit)
    func testMenuImageIsNotATemplate() {
        let point = CGFloat(LampIcon.menuPointSize)
        let data = LampIcon.png(pixelHeight: LampIcon.menuPointSize, appearance: .running)
        let rep = NSBitmapImageRep(data: data)
        XCTAssertNotNil(rep)
        XCTAssertEqual(rep?.pixelsHigh, LampIcon.menuPointSize)
        let width = point * CGFloat(rep?.pixelsWide ?? 0) / CGFloat(rep?.pixelsHigh ?? 1)
        rep?.size = NSSize(width: width, height: point)
        let image = NSImage(size: NSSize(width: width, height: point))
        if let rep { image.addRepresentation(rep) }
        image.isTemplate = LampIcon.menuImageIsTemplate
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size.height, point)
        XCTAssertGreaterThan(image.size.width, 0)
    }
    #endif

    /// 同梱 icns は、切り抜いた PNG をこの順で束ねたものとバイト一致する。
    func testFinderIconMatchesMaskedArtwork() throws {
        let root = repoRoot()
        let iconset = root.appendingPathComponent("AppBundle/AppIcon.iconset")
        let entries: [(String, String, Int)] = [
            ("icp4", "icon_16x16.png", 16),
            ("icp5", "icon_32x32.png", 32),
            ("ic11", "icon_16x16@2x.png", 32),
            ("ic12", "icon_32x32@2x.png", 64),
            ("ic07", "icon_128x128.png", 128),
            ("ic08", "icon_256x256.png", 256),
            ("ic09", "icon_512x512.png", 512),
            ("ic10", "icon_512x512@2x.png", 1024),
        ]
        var body = Data()
        var present = Set<Int>()
        for (type, name, side) in entries {
            let url = iconset.appendingPathComponent(name)
            let png = try Data(contentsOf: url)
            XCTAssertEqual(pngSide(png), side, name)
            let sample = try samplePNG(url)
            XCTAssertEqual(sample.side, side, name)
            XCTAssertEqual(sample.corners, [0, 0, 0, 0], "\(name) corners")
            XCTAssertEqual(sample.edges, [0, 0, 0, 0], "\(name) edges")
            XCTAssertEqual(sample.center.3, 255, "\(name) center alpha")
            XCTAssertGreaterThan(sample.center.0, 200, "\(name) center")
            var chunk = Data(type.utf8)
            chunk.append(be32Data(UInt32(8 + png.count)))
            chunk.append(png)
            body.append(chunk)
            present.insert(side)
        }
        for side in [16, 32, 64, 128, 256, 512, 1024] {
            XCTAssertTrue(present.contains(side))
        }
        var icns = Data("icns".utf8)
        icns.append(be32Data(UInt32(8 + body.count)))
        icns.append(body)
        let bundled = try Data(contentsOf: root.appendingPathComponent("AppBundle/AppIcon.icns"))
        XCTAssertEqual(bundled, icns)
        let sizes = pngSizes(in: bundled)
        XCTAssertEqual(sizes["icp4"], 16)
        XCTAssertEqual(sizes["icp5"], 32)
        XCTAssertEqual(sizes["ic11"], 32)
        XCTAssertEqual(sizes["ic12"], 64)
        XCTAssertEqual(sizes["ic07"], 128)
        XCTAssertEqual(sizes["ic08"], 256)
        XCTAssertEqual(sizes["ic09"], 512)
        XCTAssertEqual(sizes["ic10"], 1024)
    }

    /// 取っ手・フタ・雲の範囲が、角丸の内側に余裕を持って入る。
    func testLampArtworkFitsInsideTheRoundedRect() throws {
        let root = repoRoot()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/make-app-icon.py").path, "--check-fit"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, err + text)
        let line = text.split(separator: "\n").first { $0.hasPrefix("clearance_px=") }
        let value = Double(line?.dropFirst("clearance_px=".count) ?? "")
        XCTAssertGreaterThan(value ?? 0, 0.5, text)
        XCTAssertTrue(text.contains("content="), text)
    }

    func testWriteIconArtifacts() throws {
        let dir = URL(fileURLWithPath: "/opt/cursor/artifacts")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let backgrounds: [(String, (UInt8, UInt8, UInt8))] = [
            ("light", (244, 244, 246)),
            ("dark", (28, 28, 30)),
        ]
        let states: [(String, LampAppearance)] = [
            ("running", .running),
            ("paused", .paused),
            ("warning", .warning),
        ]
        for (backName, background) in backgrounds {
            for (stateName, appearance) in states {
                let shown = LampIcon.flattenedPNG(
                    pixelHeight: 18,
                    appearance: appearance,
                    background: background,
                    magnification: 8
                )
                try shown.write(to: dir.appendingPathComponent("menu-\(backName)-\(stateName).png"))
                let large = LampIcon.flattenedPNG(
                    pixelHeight: 54,
                    appearance: appearance,
                    background: background,
                    magnification: 4
                )
                try large.write(to: dir.appendingPathComponent("menu-\(backName)-\(stateName)-large.png"))
            }
        }
        let iconset = repoRoot().appendingPathComponent("AppBundle/AppIcon.iconset")
        try Data(contentsOf: iconset.appendingPathComponent("icon_512x512.png"))
            .write(to: dir.appendingPathComponent("finder-icon-512.png"))
        try Data(contentsOf: iconset.appendingPathComponent("icon_32x32.png"))
            .write(to: dir.appendingPathComponent("finder-icon-32.png"))
    }

    private func goldCount(_ pixels: [UInt8]) -> Int {
        count(pixels) {
            let r = Int($0.r), g = Int($0.g), b = Int($0.b)
            return r > 190 && g > 150 && g > b && r > b && $0.a > 200
        }
    }
    private func smokeCount(_ pixels: [UInt8]) -> Int {
        count(pixels) {
            let r = Int($0.r), g = Int($0.g), b = Int($0.b)
            return $0.a > 80 && b > g + 10 && b > 90 && r > 40 && r < b + 30
        }
    }
    /// 背景の紺（縁の色）が、見える濃さで残っていないこと。
    private func navyFringe(_ pixels: [UInt8]) -> Int {
        count(pixels) {
            let r = Int($0.r), g = Int($0.g), b = Int($0.b)
            let nearBackground = abs(r - 11) + abs(g - 3) + abs(b - 45) < 48
            return $0.a > 24 && nearBackground && b > r && b > g
        }
    }
    private func whiteCount(_ pixels: [UInt8]) -> Int { count(pixels) { $0.r > 240 && $0.g > 240 && $0.b > 240 && $0.a > 200 } }
    private func redCount(_ pixels: [UInt8]) -> Int { count(pixels) { $0.r > 170 && $0.g < 80 && $0.b < 80 && $0.a > 200 } }

    private func cornerAlphas(_ pixels: [UInt8], width: Int, height: Int) -> [Int] {
        let points = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
        return points.map { pixels[($0.1 * width + $0.0) * 4 + 3] }.map(Int.init)
    }

    private func isPurple(_ pixel: Pixel) -> Bool {
        let green = Int(pixel.g)
        let blue = Int(pixel.b)
        return pixel.a > 40 && blue > green + 10 && blue > Int(pixel.r) && blue > 90
    }

    /// 紫の雲を除いたランプ本体の範囲。
    private func goldBounds(_ pixels: [UInt8], width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let pixel = Pixel(
                    r: pixels[index],
                    g: pixels[index + 1],
                    b: pixels[index + 2],
                    a: pixels[index + 3]
                )
                if pixel.a > 40 && !isPurple(pixel) {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        return (minX, minY, maxX, maxY)
    }

    private func contrast(_ pixels: [UInt8], background: (Int, Int, Int)) -> Int {
        var seen = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[index + 3])
            guard a > 0 else { continue }
            let r = (Int(pixels[index]) * a + background.0 * (255 - a)) / 255
            let g = (Int(pixels[index + 1]) * a + background.1 * (255 - a)) / 255
            let b = (Int(pixels[index + 2]) * a + background.2 * (255 - a)) / 255
            let distance = abs(r - background.0) + abs(g - background.1) + abs(b - background.2)
            if distance > 80 { seen += 1 }
        }
        return seen
    }

    private func opaqueBounds(_ pixels: [UInt8], width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        return (minX, minY, maxX, maxY)
    }

    private func count(_ pixels: [UInt8], where match: (Pixel) -> Bool) -> Int {
        var seen = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let pixel = Pixel(r: pixels[index], g: pixels[index + 1], b: pixels[index + 2], a: pixels[index + 3])
            if match(pixel) { seen += 1 }
        }
        return seen
    }

    private struct Pixel {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8
    }

    private func pngSizes(in icns: Data) -> [String: Int] {
        var sizes: [String: Int] = [:]
        var offset = 8
        while offset + 8 <= icns.count {
            let typeEnd = offset + 4
            let type = String(data: icns.subdata(in: offset..<typeEnd), encoding: .ascii) ?? ""
            let length = Int(be32(icns, offset + 4))
            guard length >= 8, offset + length <= icns.count else { break }
            let payload = icns.subdata(in: (offset + 8)..<(offset + length))
            if let side = pngSide(payload) {
                sizes[type] = side
            }
            offset += length
        }
        return sizes
    }

    private func pngSide(_ png: Data) -> Int? {
        let magic = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard png.count >= 24, png.prefix(8) == magic else { return nil }
        guard String(data: png.subdata(in: 12..<16), encoding: .ascii) == "IHDR" else { return nil }
        let width = Int(be32(png, 16))
        let height = Int(be32(png, 20))
        guard width == height else { return nil }
        return width
    }

    private struct PNGSample {
        var side: Int
        var corners: [Int]
        var edges: [Int]
        var center: (Int, Int, Int, Int)
    }

    /// 角・辺の中央・中央画素。切り抜きの検査は、icns を組み立てるスクリプトとは別の読み取りで行う。
    private func samplePNG(_ url: URL) throws -> PNGSample {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.probeSource, url.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, err)
        let nums = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        XCTAssertEqual(nums.count, 13, text)
        return PNGSample(
            side: nums[0],
            corners: Array(nums[1..<5]),
            edges: Array(nums[5..<9]),
            center: (nums[9], nums[10], nums[11], nums[12])
        )
    }

    private static let probeSource = """
    import struct, sys, zlib
    data = open(sys.argv[1], "rb").read()
    assert data[:8] == b"\\x89PNG\\r\\n\\x1a\\n"
    pos = 8
    width = height = None
    idat = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos+4])[0]
        kind = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit, color = struct.unpack(">IIBB", chunk[:10])
            assert bit == 8 and color == 6
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    raw = zlib.decompress(idat)
    stride = width * 4
    rows = []
    index = 0
    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        return a if pa <= pb and pa <= pc else (b if pb <= pc else c)
    for _ in range(height):
        filt = raw[index]
        index += 1
        row = bytearray(raw[index:index+stride])
        index += stride
        up = rows[-1] if rows else bytearray(stride)
        if filt == 1:
            for i in range(stride):
                row[i] = (row[i] + (row[i-4] if i >= 4 else 0)) & 255
        elif filt == 2:
            for i in range(stride):
                row[i] = (row[i] + up[i]) & 255
        elif filt == 3:
            for i in range(stride):
                left = row[i-4] if i >= 4 else 0
                row[i] = (row[i] + ((left + up[i]) // 2)) & 255
        elif filt == 4:
            for i in range(stride):
                left = row[i-4] if i >= 4 else 0
                up_left = up[i-4] if i >= 4 else 0
                row[i] = (row[i] + paeth(left, up[i], up_left)) & 255
        elif filt != 0:
            raise SystemExit("filter %s" % filt)
        rows.append(row)
    def pix(x, y):
        i = x * 4
        return rows[y][i:i+4]
    points = [(0, 0), (width-1, 0), (0, height-1), (width-1, height-1),
              (0, height // 2), (width-1, height // 2), (width // 2, 0), (width // 2, height-1)]
    center = pix(width // 2, height // 2)
    nums = [width] + [pix(x, y)[3] for x, y in points] + list(center)
    print(" ".join(str(n) for n in nums))
    """

    private func be32Data(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<(start + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
