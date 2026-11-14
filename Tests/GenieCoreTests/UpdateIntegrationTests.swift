import Foundation
import XCTest
@testable import GenieCore

final class UpdateIntegrationTests: XCTestCase {
    func testMenuBuildsUpdateRowsAfterVersionAndBeforePhase() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/GenieMenuBarApp.swift"), encoding: .utf8)
        let populate = try XCTUnwrap(source.components(separatedBy: "private func populate(_ menu: NSMenu) {").dropFirst().first)
        let rows = populate.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let version = try XCTUnwrap(rows.firstIndex(of: "label(menuVersionLine)"))
        XCTAssertEqual(rows[version + 1], "addUpdateRows(to: menu)")
        XCTAssertEqual(rows[version + 2], "label(phase)")
        XCTAssertTrue(source.contains("func menuWillOpen(_ menu: NSMenu)"))
        XCTAssertTrue(source.contains("populate(menu)"))
    }

    func testUpdateMenuRowsDispatchTheirRepresentedActions() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/GenieMenuBarApp.swift"), encoding: .utf8)
        let rows = try methodBody(named: "addUpdateRows", in: source)
        XCTAssertTrue(rows.contains("let item = NSMenuItem(title: title, action: #selector(updateMenuAction(_:)), keyEquivalent: \"\")"))
        XCTAssertTrue(rows.contains("item.target = self"))
        XCTAssertTrue(rows.contains("item.representedObject = action"))

        let selection = try methodBody(named: "updateMenuAction", in: source)
        XCTAssertTrue(selection.contains("guard let action = sender.representedObject as? UpdateAction else { return }"))
        XCTAssertTrue(selection.contains("performUpdateAction(action)"))
    }

    func testUpdateActionsDispatchCheckSkipAndValidatedReleaseUrlWithoutNotices() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/GenieMenuBarApp.swift"), encoding: .utf8)
        let action = try methodBody(named: "performUpdateAction", in: source)
        XCTAssertTrue(action.contains("case .checkNow"))
        XCTAssertTrue(action.contains("await updateChecker.requestCheck()"))
        XCTAssertTrue(action.contains("case .skip(let version)"))
        XCTAssertTrue(action.contains("await updateChecker.skip(version)"))
        XCTAssertTrue(action.contains("updateSnapshot = await updateChecker.snapshot()"))
        XCTAssertTrue(action.contains("case .openRelease(let version)"))
        XCTAssertTrue(action.contains("UpdateMenu.releaseURL(for: version)"))
        XCTAssertTrue(action.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(action.contains("NSAlert"))
        XCTAssertFalse(action.contains("UNUserNotificationCenter"))
        XCTAssertFalse(action.contains("NSUserNotification"))
        XCTAssertFalse(action.localizedCaseInsensitiveContains("download"))
        XCTAssertFalse(action.localizedCaseInsensitiveContains("install"))
        XCTAssertFalse(action.contains("html_url"))
    }

    func testUpdatePolicyDoesNotReadOrWriteUserDefaultsDirectly() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieCore/UpdateCheck.swift"), encoding: .utf8)
        let policy = try XCTUnwrap(source.components(separatedBy: "enum UpdatePolicy").dropFirst().first)
        let end = policy.range(of: "enum UpdatePreferences")?.lowerBound ?? policy.endIndex
        XCTAssertFalse(policy[..<end].contains("UserDefaults"))
        XCTAssertTrue(source.contains("GenieUpdateSkippedVersion"))
    }

    func testSpecAndReadmeDescribeCheckOnlyUpdates() throws {
        let root = repoRoot()
        let spec = try String(contentsOf: root.appendingPathComponent("SPEC.md"), encoding: .utf8)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(spec.contains("アップデート確認"))
        XCTAssertTrue(spec.contains("認証なし"))
        XCTAssertTrue(spec.contains("通知、ダイアログ、ダウンロード、入れ替えは行わない"))
        XCTAssertTrue(readme.contains("リリース版は起動時と成功後24時間"))
        XCTAssertTrue(readme.contains("ダウンロードと入れ替えは行いません"))
    }

    private func methodBody(named name: String, in source: String) throws -> String {
        let marker = "func \(name)"
        let start = try XCTUnwrap(source.range(of: marker))
        let tail = source[start.lowerBound...]
        let next = tail.dropFirst(marker.count).range(of: "\n    }")
        return String(tail[..<(next?.upperBound ?? tail.endIndex)])
    }
}
