import XCTest
@testable import GenieCore
#if canImport(AppKit)
import AppKit
#endif

/// メニューバーの印と Finder のアイコンを、できた画像の画素で測る。
/// 縁のぼかしは許す。描画は alpha が 128 以上の画素。余白は alpha が 0 より大きい画素で測る。
/// 色は黒だけで、幅は @1x の自然な幅を整数倍する。引き伸ばさない。
final class LampIconTests: XCTestCase {
    private let appearances: [LampAppearance] = [.running, .paused, .warning]
    private let light = (UInt8(244), UInt8(244), UInt8(246))
    private let dark = (UInt8(28), UInt8(28), UInt8(30))

    func testMenuImageIsTemplate() throws {
        XCTAssertTrue(LampIcon.menuImageIsTemplate)
        #if canImport(AppKit)
        for appearance in appearances {
            let image = LampIcon.menuImage(for: appearance)
            XCTAssertTrue(image.isTemplate, "\(appearance)")
            XCTAssertEqual(image.size.height, CGFloat(LampIcon.menuPointSize), accuracy: 0.01)
            let raster = LampIcon.rgba(pixelHeight: LampIcon.menuPointSize, appearance: appearance)
            XCTAssertEqual(image.size.width, CGFloat(LampIcon.menuPointSize * raster.width) / CGFloat(raster.height), accuracy: 0.01)
            var seenHeights = Set<Int>()
            for rep in image.representations {
                guard let bitmap = rep as? NSBitmapImageRep else {
                    XCTFail("表現がビットマップではありません")
                    continue
                }
                seenHeights.insert(bitmap.pixelsHigh)
                let pixels = LampIcon.rgba(pixelHeight: bitmap.pixelsHigh, appearance: appearance)
                XCTAssertEqual(bitmap.pixelsWide, pixels.width)
                XCTAssertEqual(bitmap.pixelsHigh, pixels.height)
                var alphaMismatch = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                            alphaMismatch += 1
                            continue
                        }
                        let alpha = Int((color.alphaComponent * 255).rounded())
                        let expected = Int(pixels.pixels[(y * pixels.width + x) * 4 + 3])
                        if alpha != expected { alphaMismatch += 1 }
                    }
                }
                XCTAssertEqual(alphaMismatch, 0, "\(appearance) \(bitmap.pixelsHigh)")
            }
            XCTAssertEqual(seenHeights, Set([18, 36, 54]))
        }
        #endif
    }

    func testPixelsStayBlack() {
        for image in rasters() {
            var colored = 0
            for index in stride(from: 0, to: image.pixels.count, by: 4) {
                if image.pixels[index] != 0 || image.pixels[index + 1] != 0 || image.pixels[index + 2] != 0 {
                    colored += 1
                }
            }
            XCTAssertEqual(colored, 0, image.name)
        }
        for file in menuFiles() + referenceFiles() {
            let image = tryDecode(file)
            XCTAssertGreaterThan(image.width, 0, file.lastPathComponent)
            var colored = 0
            for index in stride(from: 0, to: image.pixels.count, by: 4) {
                if image.pixels[index] != 0 || image.pixels[index + 1] != 0 || image.pixels[index + 2] != 0 {
                    colored += 1
                }
            }
            XCTAssertEqual(colored, 0, file.lastPathComponent)
        }
    }

    func testMenuHeights() {
        for scale in [1, 2, 3] {
            for appearance in appearances {
                let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: appearance)
                XCTAssertEqual(image.height, 18 * scale)
                XCTAssertEqual(image.pixels.count, image.width * image.height * 4)
            }
            let header = tryDecode(menuURL(scale: scale, appearance: .running))
            XCTAssertEqual(header.height, 18 * scale)
        }
    }

    func testMenuWidthsFollowThePicture() {
        let base = LampIcon.rgba(pixelHeight: 18, appearance: .running)
        XCTAssertGreaterThan(base.width, 0)
        for scale in [1, 2, 3] {
            for appearance in appearances {
                let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: appearance)
                XCTAssertEqual(image.width, base.width * scale, "\(appearance) @\(scale)")
                let file = tryDecode(menuURL(scale: scale, appearance: appearance))
                XCTAssertEqual(file.width, base.width * scale)
            }
            let reference = tryDecode(referenceURL(scale: scale))
            XCTAssertEqual(reference.width, base.width * scale)
            XCTAssertEqual(reference.height, 18 * scale)
        }
    }

    func testMenuHasNoPadding() {
        for image in rasters() {
            let bounds = bounds(of: image.pixels, width: image.width, height: image.height) { $0 > 0 }
            XCTAssertEqual(bounds.minX, 0, image.name)
            XCTAssertEqual(bounds.minY, 0, image.name)
            XCTAssertEqual(bounds.maxX, image.width - 1, image.name)
            XCTAssertEqual(bounds.maxY, image.height - 1, image.name)
        }
    }

    func testStrokesAreThickEnough() {
        for image in rasters() {
            let scale = image.height / 18
            let lost = openingLost(drawn(image.pixels, width: image.width), width: image.width, height: image.height, n: 2 * scale)
            XCTAssertEqual(lost, 0, image.name)
        }
    }

    func testHandleHoleRemainsAtSixteenPixels() {
        for image in rasters() {
            let scale = image.height / 18
            let native = drawn(image.pixels, width: image.width)
            XCTAssertGreaterThanOrEqual(enclosedRegions(native, width: image.width, height: image.height).count, 1, image.name)
            let small = areaAverage(image.pixels, width: image.width, height: image.height, dw: 20, dh: 16)
            let smallDrawn = drawn(small, width: 20)
            let holes = enclosedRegions(smallDrawn, width: 20, height: 16)
            XCTAssertGreaterThanOrEqual(holes.count, 1, "\(image.name) 16px")
            XCTAssertGreaterThanOrEqual(holes.max() ?? 0, 1, image.name)
            let parts = components(smallDrawn, width: 20, height: 16)
            let total = smallDrawn.count
            XCTAssertGreaterThan(total, 0)
            XCTAssertGreaterThanOrEqual(Double(parts[0].count), 0.70 * Double(total), image.name)
            _ = scale
        }
    }

    func testLampMatchesTheApprovedMask() {
        for scale in [1, 2, 3] {
            let reference = drawn(tryDecode(referenceURL(scale: scale)).pixels, width: tryDecode(referenceURL(scale: scale)).width)
            let width = tryDecode(referenceURL(scale: scale)).width
            let height = 18 * scale
            for appearance in appearances {
                let image = LampIcon.rgba(pixelHeight: height, appearance: appearance)
                let lamp = components(drawn(image.pixels, width: image.width), width: image.width, height: image.height)[0]
                XCTAssertEqual(lamp.symmetricDifference(reference).count, 0, "\(appearance) @\(scale)")
                XCTAssertEqual(image.width, width)
            }
        }
    }

    func testRunningCloud() {
        for scale in [1, 2, 3] {
            let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: .running)
            let parts = parts(of: image)
            let others = Array(parts.components.dropFirst())
            let pixels = others.reduce(0) { $0 + $1.count }
            XCTAssertGreaterThanOrEqual(others.count, 1)
            XCTAssertGreaterThanOrEqual(pixels, 4 * scale * scale)
            XCTAssertEqual(outsideFrame(others, lamp: parts.lamp, width: image.width, height: image.height), 0)
            XCTAssertEqual(stray(others, lamp: parts.lamp), 0)
        }
    }

    func testPausedBars() {
        for scale in [1, 2, 3] {
            let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: .paused)
            let parts = parts(of: image)
            let others = Array(parts.components.dropFirst())
            XCTAssertEqual(others.count, 2, "@\(scale)")
            let boxes = others.map(box).sorted { $0.minX < $1.minX }
            for item in boxes {
                XCTAssertGreaterThanOrEqual(item.width, 2 * scale)
                XCTAssertLessThanOrEqual(item.width, 3 * scale)
                XCTAssertGreaterThanOrEqual(item.height, 6 * scale)
                XCTAssertGreaterThanOrEqual(Double(item.height) / Double(item.width), 2)
                XCTAssertGreaterThanOrEqual(item.fill, 0.9)
            }
            XCTAssertEqual(boxes[0].minY, boxes[1].minY)
            XCTAssertEqual(boxes[0].maxY, boxes[1].maxY)
            XCTAssertGreaterThanOrEqual(boxes[1].minX - boxes[0].maxX - 1, scale)
            XCTAssertEqual(outsideFrame(others, lamp: parts.lamp, width: image.width, height: image.height), 0)
        }
    }

    func testWarningMark() {
        for scale in [1, 2, 3] {
            let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: .warning)
            let parts = parts(of: image)
            let others = Array(parts.components.dropFirst()).sorted { box($0).minY < box($1).minY }
            XCTAssertEqual(others.count, 2, "@\(scale)")
            let stem = box(others[0])
            let dot = box(others[1])
            XCTAssertGreaterThanOrEqual(stem.width, 2 * scale)
            XCTAssertLessThanOrEqual(stem.width, 3 * scale)
            XCTAssertGreaterThanOrEqual(stem.height, 4 * scale)
            XCTAssertGreaterThanOrEqual(Double(stem.height) / Double(stem.width), 2)
            XCTAssertEqual(dot.width, dot.height)
            XCTAssertGreaterThanOrEqual(dot.width, 2 * scale)
            XCTAssertLessThanOrEqual(dot.width, 3 * scale)
            XCTAssertLessThanOrEqual(abs(stem.centerX - dot.centerX), Double(scale))
            XCTAssertGreaterThanOrEqual(dot.minY - stem.maxY - 1, scale)
            XCTAssertEqual(outsideFrame(others, lamp: parts.lamp, width: image.width, height: image.height), 0)
        }
    }

    func testSymbolsStayAboveTheSpout() {
        for image in rasters() {
            let scale = image.height / 18
            let parts = parts(of: image)
            let others = Array(parts.components.dropFirst())
            XCTAssertEqual(outsideFrame(others, lamp: parts.lamp, width: image.width, height: image.height), 0, image.name)
            var nearest = Int.max
            for point in others.joined() {
                for lamp in parts.lamp {
                    nearest = min(nearest, max(abs(point.x - lamp.x), abs(point.y - lamp.y)))
                }
            }
            XCTAssertGreaterThanOrEqual(nearest, scale + 1, image.name)
        }
    }

    func testLampBodyMatchesAcrossStates() {
        for scale in [1, 2, 3] {
            let lamps = appearances.map { appearance -> Set<Point> in
                let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: appearance)
                return parts(of: image).lamp
            }
            XCTAssertEqual(lamps[0], lamps[1])
            XCTAssertEqual(lamps[1], lamps[2])
        }
    }

    func testBarsAndScreenshots() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("genie-logo-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        var sheets: [(String, Data)] = []
        let menu = try menuSheet()
        let menuURL = temp.appendingPathComponent("menu-bar-marks.png")
        try menu.write(to: menuURL)
        let menuRead = try Data(contentsOf: menuURL)
        XCTAssertEqual(menuRead, menu)
        XCTAssertEqual(Array(menuRead.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        sheets.append(("menu-bar-marks.png", menu))

        let finder = try runMeasure(screenshots: temp)
        let finderURL = temp.appendingPathComponent("finder-before-after.png")
        let finderRead = try Data(contentsOf: finderURL)
        XCTAssertGreaterThan(finderRead.count, 1000)
        XCTAssertEqual(Array(finderRead.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        sheets.append(("finder-before-after.png", finderRead))
        _ = finder

        for scale in [1, 2, 3] {
            var shapes: [LampAppearance: Set<Point>] = [:]
            for appearance in appearances {
                let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: appearance)
                let lightPixels = composite(image.pixels, width: image.width, height: image.height, background: light, ink: 0)
                let darkPixels = composite(image.pixels, width: image.width, height: image.height, background: dark, ink: 255)
                XCTAssertLessThanOrEqual(channelError(lightPixels, source: image.pixels, background: light, ink: 0), 1)
                XCTAssertLessThanOrEqual(channelError(darkPixels, source: image.pixels, background: dark, ink: 255), 1)
                let lightShape = shape(lightPixels, width: image.width, height: image.height, background: light)
                let darkShape = shape(darkPixels, width: image.width, height: image.height, background: dark)
                let expected = drawn(image.pixels, width: image.width)
                XCTAssertEqual(lightShape.symmetricDifference(expected).count, 0)
                XCTAssertEqual(lightShape.symmetricDifference(darkShape).count, 0)
                XCTAssertGreaterThanOrEqual(contrast(lightPixels, width: image.width, drawn: expected, background: light), 200)
                XCTAssertGreaterThanOrEqual(contrast(darkPixels, width: image.width, drawn: expected, background: dark), 200)
                shapes[appearance] = lightShape
            }
            let pairs: [(LampAppearance, LampAppearance)] = [(.running, .paused), (.running, .warning), (.paused, .warning)]
            for (left, right) in pairs {
                let diff = shapes[left]!.symmetricDifference(shapes[right]!).count
                XCTAssertGreaterThanOrEqual(diff, 8 * scale * scale, "\(left) \(right) @\(scale)")
            }
        }

        let artifacts = URL(fileURLWithPath: "/opt/cursor/artifacts")
        if (try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)) != nil {
            for (name, data) in sheets {
                let url = artifacts.appendingPathComponent(name)
                try data.write(to: url)
                let read = try Data(contentsOf: url)
                XCTAssertEqual(read, data, name)
            }
        }
    }

    func testAppearancePriorityAndLabels() {
        let idle = snapshot()
        let paused = snapshot(paused: true)
        let attention = snapshot(holdNotice: "reply_held_empty_list")
        let both = snapshot(paused: true, holdNotice: "reply_held_empty_list")
        let cases: [(EngineSnapshot?, LampAppearance, String)] = [
            (nil, .running, "ジーニー 監視中"),
            (idle, .running, "ジーニー 監視中"),
            (paused, .paused, "ジーニー 一時停止"),
            (attention, .warning, "ジーニー 要確認"),
            (both, .warning, "ジーニー 要確認"),
        ]
        for item in cases {
            let appearance = LampIcon.appearance(for: item.0)
            XCTAssertEqual(appearance, item.1)
            XCTAssertEqual(LampIcon.statusLabel(for: appearance), item.2)
        }
        #if canImport(AppKit)
        let button = NSButton()
        let order: [(EngineSnapshot, LampAppearance)] = [
            (idle, .running),
            (paused, .paused),
            (attention, .warning),
            (idle, .running),
        ]
        for item in order {
            LampIcon.applyStatus(to: button, snapshot: item.1 == .running ? idle : item.0)
            let label = LampIcon.statusLabel(for: item.1)
            XCTAssertEqual(button.toolTip, label)
            XCTAssertEqual(button.accessibilityLabel(), label)
            XCTAssertTrue(button.image?.isTemplate == true)
            guard let bitmap = button.image?.representations.compactMap({ $0 as? NSBitmapImageRep }).first(where: { $0.pixelsHigh == 18 }) else {
                XCTFail("18px の表現がありません")
                continue
            }
            let expected = LampIcon.rgba(pixelHeight: 18, appearance: item.1)
            XCTAssertEqual(bitmap.pixelsWide, expected.width)
            var mismatch = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        mismatch += 1
                        continue
                    }
                    let alpha = Int((color.alphaComponent * 255).rounded())
                    if alpha != Int(expected.pixels[(y * expected.width + x) * 4 + 3]) { mismatch += 1 }
                }
            }
            XCTAssertEqual(mismatch, 0, label)
        }
        #endif
    }

    func testMenuPngMatchesTheScript() throws {
        let files = menuFiles() + referenceFiles()
        let before = try files.map { try Data(contentsOf: $0) }
        let result = try runPython(script: repoRoot().appendingPathComponent("scripts/make-menu-icon.py"), arguments: [])
        XCTAssertEqual(result.status, 0, result.err + result.out)
        let after = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(after, before)
        for scale in [1, 2, 3] {
            let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: .running)
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertEqual(image.pixels.count, image.width * image.height * 4)
        }
    }

    func testFinderIconSet() throws {
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
        let extras = [("icon_128x128@2x.png", 256), ("icon_256x256@2x.png", 512)]
        for (name, side) in extras {
            let data = try Data(contentsOf: iconset.appendingPathComponent(name))
            XCTAssertEqual(pngSize(data)?.width, side, name)
            XCTAssertEqual(pngSize(data)?.height, side, name)
        }
        var body = Data()
        for (type, name, side) in entries {
            let png = try Data(contentsOf: iconset.appendingPathComponent(name))
            XCTAssertEqual(pngSize(png)?.width, side, name)
            var chunk = Data(type.utf8)
            chunk.append(be32Data(UInt32(8 + png.count)))
            chunk.append(png)
            body.append(chunk)
        }
        var icns = Data("icns".utf8)
        icns.append(be32Data(UInt32(8 + body.count)))
        icns.append(body)
        let bundled = try Data(contentsOf: root.appendingPathComponent("AppBundle/AppIcon.icns"))
        XCTAssertEqual(bundled, icns)
    }

    func testFinderPixels() throws {
        let check = try runPython(
            script: repoRoot().appendingPathComponent("scripts/make-app-icon.py"),
            arguments: ["--check-fit"]
        )
        XCTAssertEqual(check.status, 0, check.err + check.out)
        let printed = check.out.split(separator: "\n").first { $0.hasPrefix("clearance_px=") }
        let scriptClearance = Double(printed?.dropFirst("clearance_px=".count) ?? "") ?? -1
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("genie-logo-measure", isDirectory: true)
        let measured = try runMeasure(screenshots: nil)
        for key in ["master_alpha", "alpha_mismatch", "interior_not_black", "purple", "fringe_not_black", "mask_alpha", "bbox_over", "rgb_over", "clearance_below"] {
            XCTAssertEqual(measured[key] ?? -1, 0, key)
        }
        let independent = Double(measured["clearance_milli"] ?? 0) / 1000
        XCTAssertGreaterThan(independent, 0.5)
        XCTAssertEqual(scriptClearance, independent, accuracy: 0.02, check.out)
        _ = temp
    }

    func testFinderMatchesTheScript() throws {
        let root = repoRoot()
        var files = iconFiles()
        files.append(root.appendingPathComponent("AppBundle/AppIcon.icns"))
        files.append(root.appendingPathComponent("AppBundle/FinderLamp-1024.png"))
        let before = try files.map { try Data(contentsOf: $0) }
        let result = try runPython(script: root.appendingPathComponent("scripts/make-app-icon.py"), arguments: [])
        XCTAssertEqual(result.status, 0, result.err + result.out)
        let after = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(after, before)
    }

    func testSpecMenuLine() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).first { $0.hasPrefix("- メニュー表示:") }
        let menu = String(line ?? "")
        XCTAssertFalse(menu.isEmpty)
        for word in ["template", "isTemplate", "黒と透明", "18pt", "@1x/@2x/@3x", "形", "背景は黒", "824", "185", "切らず"] {
            XCTAssertTrue(menu.contains(word), word)
        }
        for word in ["金色のランプ", "色のまま出し", "template にはしない", "赤い印", "絵の縁の色"] {
            XCTAssertFalse(menu.contains(word), word)
        }
    }

    private struct Raster {
        var name: String
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    private struct Point: Hashable {
        var x: Int
        var y: Int
    }

    private struct Box {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var width: Int
        var height: Int
        var fill: Double
        var centerX: Double
    }

    private struct Parts {
        var components: [Set<Point>]
        var lamp: Set<Point>
    }

    private func rasters() -> [Raster] {
        var images: [Raster] = []
        for scale in [1, 2, 3] {
            for appearance in appearances {
                let image = LampIcon.rgba(pixelHeight: 18 * scale, appearance: appearance)
                images.append(Raster(name: "\(appearance)@\(scale)", width: image.width, height: image.height, pixels: image.pixels))
            }
        }
        return images
    }

    private func drawn(_ pixels: [UInt8], width: Int) -> Set<Point> {
        var points = Set<Point>()
        let height = pixels.count / (width * 4)
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 128 {
                points.insert(Point(x: x, y: y))
            }
        }
        return points
    }

    private func components(_ points: Set<Point>, width: Int, height: Int) -> [Set<Point>] {
        var remaining = points
        var found: [Set<Point>] = []
        while let start = remaining.first {
            var stack = [start]
            var group: Set<Point> = []
            remaining.remove(start)
            while let point = stack.popLast() {
                group.insert(point)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let next = Point(x: point.x + dx, y: point.y + dy)
                        if next.x < 0 || next.y < 0 || next.x >= width || next.y >= height { continue }
                        if remaining.remove(next) != nil { stack.append(next) }
                    }
                }
            }
            found.append(group)
        }
        return found.sorted { $0.count > $1.count }
    }

    private func enclosedRegions(_ points: Set<Point>, width: Int, height: Int) -> [Int] {
        var outside = Set<Point>()
        var stack: [Point] = []
        func push(_ point: Point) {
            if point.x < 0 || point.y < 0 || point.x >= width || point.y >= height { return }
            if points.contains(point) || outside.contains(point) { return }
            outside.insert(point)
            stack.append(point)
        }
        for x in 0..<width {
            push(Point(x: x, y: 0))
            push(Point(x: x, y: height - 1))
        }
        for y in 0..<height {
            push(Point(x: 0, y: y))
            push(Point(x: width - 1, y: y))
        }
        while let point = stack.popLast() {
            push(Point(x: point.x + 1, y: point.y))
            push(Point(x: point.x - 1, y: point.y))
            push(Point(x: point.x, y: point.y + 1))
            push(Point(x: point.x, y: point.y - 1))
        }
        var holes: [Int] = []
        var seen = outside
        for y in 0..<height {
            for x in 0..<width {
                let start = Point(x: x, y: y)
                if points.contains(start) || seen.contains(start) { continue }
                var count = 0
                var hole = [start]
                seen.insert(start)
                while let point = hole.popLast() {
                    count += 1
                    for next in [Point(x: point.x + 1, y: point.y), Point(x: point.x - 1, y: point.y), Point(x: point.x, y: point.y + 1), Point(x: point.x, y: point.y - 1)] {
                        if next.x < 0 || next.y < 0 || next.x >= width || next.y >= height { continue }
                        if points.contains(next) || seen.contains(next) { continue }
                        seen.insert(next)
                        hole.append(next)
                    }
                }
                holes.append(count)
            }
        }
        return holes
    }

    private func openingLost(_ points: Set<Point>, width: Int, height: Int, n: Int) -> Int {
        guard n > 0, width >= n, height >= n else { return points.count }
        var covered = Set<Point>()
        for y in 0...(height - n) {
            for x in 0...(width - n) {
                var good = true
                for yy in y..<(y + n) where good {
                    for xx in x..<(x + n) where !points.contains(Point(x: xx, y: yy)) {
                        good = false
                        break
                    }
                }
                if !good { continue }
                for yy in y..<(y + n) {
                    for xx in x..<(x + n) {
                        covered.insert(Point(x: xx, y: yy))
                    }
                }
            }
        }
        return points.subtracting(covered).count
    }

    private func areaAverage(_ pixels: [UInt8], width: Int, height: Int, dw: Int, dh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: dw * dh * 4)
        for y in 0..<dh {
            let y0 = Double(y) * Double(height) / Double(dh)
            let y1 = Double(y + 1) * Double(height) / Double(dh)
            for x in 0..<dw {
                let x0 = Double(x) * Double(width) / Double(dw)
                let x1 = Double(x + 1) * Double(width) / Double(dw)
                var acc = 0.0
                var area = 0.0
                let iy0 = Int(y0)
                let iy1 = min(height - 1, Int((y1 - 1e-9).nextDown))
                let ix0 = Int(x0)
                let ix1 = min(width - 1, Int((x1 - 1e-9).nextDown))
                let yEnd = max(iy0, min(height - 1, Int(y1 - 1e-9)))
                let xEnd = max(ix0, min(width - 1, Int(x1 - 1e-9)))
                for iy in iy0...yEnd {
                    let wy = min(Double(iy + 1), y1) - max(Double(iy), y0)
                    for ix in ix0...xEnd {
                        let wx = min(Double(ix + 1), x1) - max(Double(ix), x0)
                        acc += Double(pixels[(iy * width + ix) * 4 + 3]) * wx * wy
                        area += wx * wy
                    }
                }
                let alpha = area > 0 ? acc / area : 0
                out[(y * dw + x) * 4 + 3] = alpha >= 128 ? 255 : 0
                _ = (iy1, ix1)
            }
        }
        return out
    }

    private func bounds(of pixels: [UInt8], width: Int, height: Int, where match: (UInt8) -> Bool) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where match(pixels[(y * width + x) * 4 + 3]) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        return (minX, minY, maxX, maxY)
    }

    private func parts(of image: (width: Int, height: Int, pixels: [UInt8])) -> Parts {
        let groups = components(drawn(image.pixels, width: image.width), width: image.width, height: image.height)
        return Parts(components: groups, lamp: groups[0])
    }

    private func parts(of image: Raster) -> Parts {
        parts(of: (image.width, image.height, image.pixels))
    }

    private func box(_ points: Set<Point>) -> Box {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let width = maxX - minX + 1
        let height = maxY - minY + 1
        return Box(
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            width: width,
            height: height,
            fill: Double(points.count) / Double(width * height),
            centerX: (Double(minX) + Double(maxX)) / 2
        )
    }

    private func frame(of lamp: Set<Point>, width: Int) -> (spoutY: Int, center: Double) {
        let xs = lamp.map(\.x)
        let center = (Double(xs.min() ?? 0) + Double(xs.max() ?? 0)) / 2
        var spoutX = -1
        var spoutY = 0
        for point in lamp where point.x > spoutX || (point.x == spoutX && point.y < spoutY) {
            spoutX = point.x
            spoutY = point.y
        }
        _ = width
        return (spoutY, center)
    }

    private func outsideFrame(_ groups: [Set<Point>], lamp: Set<Point>, width: Int, height: Int) -> Int {
        let mark = frame(of: lamp, width: width)
        var count = 0
        for point in groups.joined() {
            if point.y >= mark.spoutY || Double(point.x) <= mark.center { count += 1 }
        }
        _ = height
        return count
    }

    private func stray(_ groups: [Set<Point>], lamp: Set<Point>) -> Int {
        let minX = lamp.map(\.x).min() ?? 0
        let maxY = lamp.map(\.y).max() ?? 0
        return groups.joined().reduce(0) { $0 + ($1.x < minX || $1.y > maxY ? 1 : 0) }
    }

    private func composite(_ pixels: [UInt8], width: Int, height: Int, background: (UInt8, UInt8, UInt8), ink: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let bg = [Int(background.0), Int(background.1), Int(background.2)]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            for channel in 0..<3 {
                let value = Double(ink * alpha + bg[channel] * (255 - alpha)) / 255
                out[index + channel] = UInt8(value.rounded())
            }
            out[index + 3] = 255
        }
        _ = (width, height)
        return out
    }

    private func channelError(_ mixed: [UInt8], source: [UInt8], background: (UInt8, UInt8, UInt8), ink: Int) -> Int {
        let bg = [Int(background.0), Int(background.1), Int(background.2)]
        var worst = 0
        for index in stride(from: 0, to: source.count, by: 4) {
            let alpha = Int(source[index + 3])
            for channel in 0..<3 {
                let expect = (ink * alpha + bg[channel] * (255 - alpha) + 127) / 255
                worst = max(worst, abs(Int(mixed[index + channel]) - expect))
            }
        }
        return worst
    }

    private func shape(_ pixels: [UInt8], width: Int, height: Int, background: (UInt8, UInt8, UInt8)) -> Set<Point> {
        var points = Set<Point>()
        let bg = [Int(background.0), Int(background.1), Int(background.2)]
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let delta = abs(Int(pixels[index]) - bg[0]) + abs(Int(pixels[index + 1]) - bg[1]) + abs(Int(pixels[index + 2]) - bg[2])
                if delta > 150 { points.insert(Point(x: x, y: y)) }
            }
        }
        return points
    }

    private func contrast(_ pixels: [UInt8], width: Int, drawn: Set<Point>, background: (UInt8, UInt8, UInt8)) -> Double {
        let backgroundY = 0.2126 * Double(background.0) + 0.7152 * Double(background.1) + 0.0722 * Double(background.2)
        var worst = Double.greatestFiniteMagnitude
        for point in drawn {
            let index = (point.y * width + point.x) * 4
            let y = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
            worst = min(worst, abs(y - backgroundY))
        }
        return worst
    }

    private func menuSheet() throws -> Data {
        let gap = 6
        let columns: [(LampAppearance, (UInt8, UInt8, UInt8), Int)] = [
            (.running, light, 0), (.paused, light, 0), (.warning, light, 0),
            (.running, dark, 255), (.paused, dark, 255), (.warning, dark, 255),
        ]
        let rows: [(Int, Int)] = [(18, 1), (18, 8), (54, 1), (54, 4)]
        var rowHeights: [Int] = []
        var rowWidths: [[Int]] = []
        var cellWidth = 0
        for (pixelHeight, magnification) in rows {
            var widths: [Int] = []
            var height = 0
            for column in columns {
                let image = LampIcon.rgba(pixelHeight: pixelHeight, appearance: column.0)
                widths.append(image.width * magnification)
                height = image.height * magnification
            }
            rowWidths.append(widths)
            rowHeights.append(height)
            cellWidth = max(cellWidth, widths.max() ?? 0)
        }
        let width = gap + columns.count * (cellWidth + gap)
        let height = gap + rowHeights.reduce(0, +) + rows.count * gap
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: canvas.count, by: 4) {
            canvas[index] = 90
            canvas[index + 1] = 90
            canvas[index + 2] = 92
            canvas[index + 3] = 255
        }
        var top = gap
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, column) in columns.enumerated() {
                let image = LampIcon.rgba(pixelHeight: row.0, appearance: column.0)
                let mixed = composite(image.pixels, width: image.width, height: image.height, background: column.1, ink: column.2)
                let left = gap + columnIndex * (cellWidth + gap)
                for y in 0..<image.height * row.1 {
                    for x in 0..<image.width * row.1 {
                        let sx = x / row.1
                        let sy = y / row.1
                        let src = (sy * image.width + sx) * 4
                        let dst = ((top + y) * width + (left + x)) * 4
                        canvas[dst] = mixed[src]
                        canvas[dst + 1] = mixed[src + 1]
                        canvas[dst + 2] = mixed[src + 2]
                        canvas[dst + 3] = 255
                    }
                }
            }
            top += rowHeights[rowIndex] + gap
        }
        return png(width: width, height: height, pixels: canvas)
    }

    private func snapshot(paused: Bool = false, holdNotice: String? = nil) -> EngineSnapshot {
        EngineSnapshot(
            paused: paused,
            cursorRowID: 0,
            enabledChatIDs: [],
            haltedChatIDs: [],
            heldCount: 0,
            heldLockCount: 0,
            lastError: nil,
            holdNotice: holdNotice,
            screenLocked: false,
            screenLock: .unlocked,
            replyFetchConfigured: true,
            webhookConfigured: true
        )
    }

    private func menuFiles() -> [URL] {
        appearances.flatMap { appearance in
            [1, 2, 3].map { menuURL(scale: $0, appearance: appearance) }
        }
    }

    private func referenceFiles() -> [URL] {
        [1, 2, 3].map { referenceURL(scale: $0) }
    }

    private func iconFiles() -> [URL] {
        let names = [
            "icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
            "icon_128x128.png", "icon_128x128@2x.png", "icon_256x256.png", "icon_256x256@2x.png",
            "icon_512x512.png", "icon_512x512@2x.png",
        ]
        return names.map { repoRoot().appendingPathComponent("AppBundle/AppIcon.iconset/\($0)") }
    }

    private func menuURL(scale: Int, appearance: LampAppearance) -> URL {
        let name: String
        switch appearance {
        case .running: name = "lamp@\(scale)x.png"
        case .paused: name = "lamp-paused@\(scale)x.png"
        case .warning: name = "lamp-warning@\(scale)x.png"
        }
        return repoRoot().appendingPathComponent("AppBundle/MenuLamp/\(name)")
    }

    private func referenceURL(scale: Int) -> URL {
        repoRoot().appendingPathComponent("AppBundle/MenuLamp/reference/lamp@\(scale)x.png")
    }

    private func tryDecode(_ url: URL) -> (width: Int, height: Int, pixels: [UInt8]) {
        guard let data = try? Data(contentsOf: url) else { return (0, 0, []) }
        return decode(data)
    }

    private func decode(_ data: Data) -> (width: Int, height: Int, pixels: [UInt8]) {
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
            if kind == "IHDR", length >= 13 {
                width = Int(be32(data, start))
                height = Int(be32(data, start + 4))
            } else if kind == "IDAT" {
                idat.append(data.subdata(in: start..<end))
            } else if kind == "IEND" {
                break
            }
            offset = end + 4
        }
        guard width > 0, height > 0, let inflated = inflateStored(idat) else { return (0, 0, []) }
        let stride = width * 4
        guard inflated.count >= height * (1 + stride) else { return (0, 0, []) }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        var cursor = 0
        for _ in 0..<height {
            if inflated[cursor] != 0 { return (0, 0, []) }
            cursor += 1
            pixels.append(contentsOf: inflated[cursor..<(cursor + stride)])
            cursor += stride
        }
        return (width, height, pixels)
    }

    private func inflateStored(_ data: Data) -> [UInt8]? {
        guard data.count >= 2, data[data.startIndex] == 0x78 else { return nil }
        var index = 2
        var out: [UInt8] = []
        while index < data.count {
            let last = data[data.startIndex + index] == 1
            index += 1
            guard index + 4 <= data.count else { return nil }
            let len = Int(data[data.startIndex + index]) | (Int(data[data.startIndex + index + 1]) << 8)
            index += 4
            guard index + len <= data.count else { return nil }
            out.append(contentsOf: data[(data.startIndex + index)..<(data.startIndex + index + len)])
            index += len
            if last { break }
        }
        return out
    }

    private func png(width: Int, height: Int, pixels: [UInt8]) -> Data {
        var raw = Data()
        for y in 0..<height {
            raw.append(0)
            let start = y * width * 4
            raw.append(contentsOf: pixels[start..<(start + width * 4)])
        }
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var ihdr = Data()
        ihdr.append(be32Data(UInt32(width)))
        ihdr.append(be32Data(UInt32(height)))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        data.append(chunk("IHDR", ihdr))
        data.append(chunk("IDAT", zlibStore(raw)))
        data.append(chunk("IEND", Data()))
        return data
    }

    private func chunk(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        out.append(be32Data(UInt32(payload.count)))
        let kind = Data(type.utf8)
        out.append(kind)
        out.append(payload)
        var crcInput = kind
        crcInput.append(payload)
        out.append(be32Data(crc32(crcInput)))
        return out
    }

    private func zlibStore(_ data: Data) -> Data {
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
            if take > 0 { out.append(data.subdata(in: offset..<(offset + take))) }
            offset += take
        } while offset < data.count
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        out.append(be32Data((b << 16) | a))
        return out
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }

    private func pngSize(_ png: Data) -> (width: Int, height: Int)? {
        guard png.count >= 24, png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        guard String(data: png.subdata(in: 12..<16), encoding: .ascii) == "IHDR" else { return nil }
        return (Int(be32(png, 16)), Int(be32(png, 20)))
    }

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

    private struct PythonResult {
        var status: Int32
        var out: String
        var err: String
    }

    private func runPython(script: URL, arguments: [String]) throws -> PythonResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return PythonResult(status: process.terminationStatus, out: out, err: err)
    }

    private func runMeasure(screenshots: URL?) throws -> [String: Int] {
        var arguments = [repoRoot().path]
        if let screenshots {
            arguments += ["--screenshots", screenshots.path]
        }
        let result = try runPython(
            script: repoRoot().appendingPathComponent("Tests/GenieCoreTests/MeasureLogo.py"),
            arguments: arguments
        )
        XCTAssertEqual(result.status, 0, result.err + result.out)
        var values: [String: Int] = [:]
        for line in result.out.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) {
                values[String(pair[0])] = value
            }
        }
        return values
    }
}
