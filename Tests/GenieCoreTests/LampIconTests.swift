import XCTest
@testable import GenieCore

final class LampIconTests: XCTestCase {
    func testStatesDifferAndReadOnLightAndDark() {
        let running = LampIcon.rgba(size: 48, appearance: .running)
        let paused = LampIcon.rgba(size: 48, appearance: .paused)
        let warning = LampIcon.rgba(size: 48, appearance: .warning)
        XCTAssertNotEqual(running, paused)
        XCTAssertNotEqual(running, warning)
        XCTAssertNotEqual(paused, warning)
        XCTAssertGreaterThan(goldCount(running), 40)
        XCTAssertGreaterThan(darkCount(running), 20)
        XCTAssertEqual(whiteCount(running), 0)
        XCTAssertGreaterThan(whiteCount(paused), 8)
        XCTAssertGreaterThan(redCount(warning), 8)
        XCTAssertEqual(redCount(running), 0)
        XCTAssertGreaterThan(semiTransparentGold(running), 5)
        for pixels in [running, paused, warning] {
            XCTAssertGreaterThan(contrast(pixels, background: (244, 244, 246)), 30)
            XCTAssertGreaterThan(contrast(pixels, background: (28, 28, 30)), 30)
        }
        let bounds = opaqueBounds(running, size: 48)
        XCTAssertGreaterThan(bounds.width, bounds.height)
    }

    func testMenuPngHeader() {
        let png = LampIcon.png(size: 16, appearance: .running)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

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

    func testWriteIconArtifacts() throws {
        let dir = URL(fileURLWithPath: "/opt/cursor/artifacts")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try LampIcon.png(size: 160, appearance: .running).write(to: dir.appendingPathComponent("lamp-running.png"))
        try LampIcon.png(size: 160, appearance: .paused).write(to: dir.appendingPathComponent("lamp-paused.png"))
        try LampIcon.png(size: 160, appearance: .warning).write(to: dir.appendingPathComponent("lamp-warning.png"))
        let iconset = repoRoot().appendingPathComponent("AppBundle/AppIcon.iconset")
        try Data(contentsOf: iconset.appendingPathComponent("icon_512x512.png"))
            .write(to: dir.appendingPathComponent("finder-icon-512.png"))
        try Data(contentsOf: iconset.appendingPathComponent("icon_32x32.png"))
            .write(to: dir.appendingPathComponent("finder-icon-32.png"))
    }

    private func goldCount(_ pixels: [UInt8]) -> Int { count(pixels) { $0.r > 180 && $0.g > 120 && $0.b < 110 && $0.a > 200 } }
    private func darkCount(_ pixels: [UInt8]) -> Int { count(pixels) { $0.r < 50 && $0.g < 40 && $0.b < 30 && $0.a > 180 } }
    private func whiteCount(_ pixels: [UInt8]) -> Int { count(pixels) { $0.r > 240 && $0.g > 240 && $0.b > 240 && $0.a > 200 } }
    private func redCount(_ pixels: [UInt8]) -> Int { count(pixels) { $0.r > 170 && $0.g < 80 && $0.b < 80 && $0.a > 200 } }
    private func semiTransparentGold(_ pixels: [UInt8]) -> Int {
        count(pixels) { $0.r > 200 && $0.g > 140 && $0.b < 140 && $0.a > 25 && $0.a < 230 }
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

    private func opaqueBounds(_ pixels: [UInt8], size: Int) -> (width: Int, height: Int) {
        var minX = size
        var minY = size
        var maxX = 0
        var maxY = 0
        for y in 0..<size {
            for x in 0..<size where pixels[(y * size + x) * 4 + 3] > 40 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        return (maxX - minX, maxY - minY)
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
