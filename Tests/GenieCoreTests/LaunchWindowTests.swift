import CoreFoundation
import Foundation
import XCTest
@testable import GenieCore

final class LaunchWindowTests: XCTestCase {
    func testMenuBarSourcesDoNotDeclareSwiftUIScenes() throws {
        let sources = try menuBarSources().map { stripComments(try String(contentsOf: $0, encoding: .utf8)) }
        for forbidden in ["Settings {", "WindowGroup", ": App {", "@NSApplicationDelegateAdaptor", "DocumentGroup", "MenuBarExtra"] {
            XCTAssertFalse(sources.contains { $0.contains(forbidden) }, forbidden)
        }
    }

    func testAppKitEntrySetsPolicyAndRestorationBeforeRun() throws {
        let source = try appSource()
        XCTAssertTrue(source.contains("@main\nenum GenieMenuBarApp"))
        let main = try XCTUnwrap(source.components(separatedBy: "static func main()").dropFirst().first)
            .components(separatedBy: "\n    }").first
        let restoration = try XCTUnwrap(main?.range(of: "WindowRestorationPolicy.disable(in: .standard)"))
        let activation = try XCTUnwrap(main?.range(of: "setActivationPolicy(.accessory)"))
        let run = try XCTUnwrap(main?.range(of: "app.run()"))
        XCTAssertLessThan(restoration.lowerBound, activation.lowerBound)
        XCTAssertLessThan(activation.lowerBound, run.lowerBound)
    }

    func testWindowRestorationPolicyOverwritesStoredTrueAndSetsMissingValue() throws {
        let savedTrueName = "MenuVersionSavedTrue-\(UUID().uuidString)"
        let savedTrue = try XCTUnwrap(UserDefaults(suiteName: savedTrueName))
        defer { savedTrue.removePersistentDomain(forName: savedTrueName) }
        savedTrue.set(true, forKey: "NSQuitAlwaysKeepsWindows")

        WindowRestorationPolicy.disable(in: savedTrue)
        XCTAssertEqual(savedTrue.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool, false)

        let missingName = "MenuVersionMissing-\(UUID().uuidString)"
        let missing = try XCTUnwrap(UserDefaults(suiteName: missingName))
        defer { missing.removePersistentDomain(forName: missingName) }
        XCTAssertNil(missing.object(forKey: "NSQuitAlwaysKeepsWindows"))
        WindowRestorationPolicy.disable(in: missing)
        XCTAssertEqual(missing.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool, false)
    }

    func testLaunchClosesExistingWindowsBeforeInstallingStatusItem() throws {
        let source = try appSource()
        let launch = try XCTUnwrap(source.components(separatedBy: "func applicationDidFinishLaunching").dropFirst().first)
            .components(separatedBy: "\n    }").first
        let close = try XCTUnwrap(launch?.range(of: "for window in NSApp.windows { window.close() }"))
        let install = try XCTUnwrap(launch?.range(of: "model.installStatusItem()"))
        XCTAssertLessThan(close.lowerBound, install.lowerBound)
    }

    func testAllowlistWindowCannotBeRestored() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/AllowlistWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("isRestorable = false"))
    }

    func testInfoPlistUsesBooleanLSUIElement() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("AppBundle/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let value = try XCTUnwrap(info["LSUIElement"] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(value), CFBooleanGetTypeID())
        XCTAssertTrue(value.boolValue)
    }

    func testAllowlistPresentIsCalledOnlyByShowAllowlist() throws {
        let source = try menuBarSources().map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        XCTAssertEqual(matches(of: #"AllowlistPanel\.present\("#, in: stripComments(source)).count, 1)
        XCTAssertTrue(stripComments(source).contains("@objc private func showAllowlist() { AllowlistPanel.present(model: self) }"))
    }

    func testOnlyAllowlistFileConstructsWindowsAndPanels() throws {
        let sources = try menuBarSources()
        let constructors = try sources.filter { url in
            let text = stripComments(try String(contentsOf: url, encoding: .utf8))
            return !matches(of: #"NS(?:Window|Panel)\s*\("#, in: text).isEmpty
        }
        XCTAssertEqual(constructors.map(\.lastPathComponent), ["AllowlistWindow.swift"])
    }

    func testSpecAndReadmeDescribeVersionAndLaunchBehavior() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        let menuLine = try XCTUnwrap(spec.split(separator: "\n").first { $0.hasPrefix("- メニュー表示:") })
        XCTAssertTrue(menuLine.contains("バージョン: v1.1.0（fe7cf02）"))
        XCTAssertTrue(menuLine.contains("バージョン: 開発版（abc1234）"))
        XCTAssertTrue(menuLine.contains("バージョン: 不明"))
        XCTAssertTrue(spec.contains("起動時に開くウィンドウは無い"))
        XCTAssertTrue(spec.contains("GenieReleaseVersion") && spec.contains("GenieGitCommit"))
        XCTAssertTrue(readme.contains("メニューの2行目にバージョン"))
        XCTAssertTrue(readme.contains("バージョン: v1.1.0（fe7cf02）"))
    }

    func testRequiredVersionAndWindowMutantsAreRegistered() throws {
        let path = repoRoot().appendingPathComponent("tools/mutants/manifest.json")
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: String]])
        let required = [
            "MV-PAREN", "MV-NOCOMMIT", "MV-VPREFIX", "MV-ANYTAG", "MV-DIRTY", "MV-ORDER",
            "MV-DEV", "MV-UNKNOWN", "MV-STAMP-DEV", "WN-SETTINGS", "WN-POLICY", "WN-RESTORE", "WN-LAUNCHPRESENT",
        ]
        for name in required {
            XCTAssertTrue(entries.contains { $0["name"] == name }, name)
        }
    }

    private func appSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/GenieMenuBarApp.swift"), encoding: .utf8)
    }

    private func menuBarSources() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: repoRoot().appendingPathComponent("Sources/GenieMenuBar"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func stripComments(_ source: String) -> String {
        let blockless = source.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
        return blockless.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
