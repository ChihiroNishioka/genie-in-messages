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

    func testPngAndIcnsHeaders() throws {
        let png = LampIcon.png(size: 16, appearance: .running)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let icns = LampIcon.appIconICNS()
        XCTAssertEqual(String(data: icns.prefix(4), encoding: .utf8), "icns")
        XCTAssertTrue(icns.range(of: Data("ic07".utf8)) != nil)
        XCTAssertTrue(icns.range(of: Data("ic08".utf8)) != nil)
        XCTAssertTrue(icns.range(of: Data([137, 80, 78, 71])) != nil)
        let icon = LampIcon.appIconRGBA(size: 32)
        XCTAssertEqual(icon[3], 0, "squircle corner stays clear")
        let mid = (16 * 32 + 16) * 4
        XCTAssertGreaterThan(icon[mid], 80)
        XCTAssertGreaterThan(icon[mid + 1], 40)
        let bundled = repoRoot().appendingPathComponent("AppBundle/AppIcon.icns")
        let existing = FileManager.default.contents(atPath: bundled.path) ?? Data()
        if existing != icns {
            try icns.write(to: URL(fileURLWithPath: "/tmp/AppIcon.icns"))
        }
        XCTAssertEqual(existing, icns)
    }

    func testWriteIconArtifacts() throws {
        let dir = URL(fileURLWithPath: "/opt/cursor/artifacts")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try LampIcon.png(size: 160, appearance: .running).write(to: dir.appendingPathComponent("lamp-running.png"))
        try LampIcon.png(size: 160, appearance: .paused).write(to: dir.appendingPathComponent("lamp-paused.png"))
        try LampIcon.png(size: 160, appearance: .warning).write(to: dir.appendingPathComponent("lamp-warning.png"))
        try LampIcon.appIconPNG(size: 512).write(to: dir.appendingPathComponent("lamp-app-icon.png"))
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
}
