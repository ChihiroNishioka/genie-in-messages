import Foundation
import XCTest
@testable import GenieCore

final class AppVersionTests: XCTestCase {
    func testReleaseLineUsesFullWidthParentheses() {
        XCTAssertEqual(
            AppVersion.menuLine(info: ["GenieReleaseVersion": "1.1.0", "GenieGitCommit": "fe7cf02"]),
            "バージョン: v1.1.0（fe7cf02）"
        )
    }

    func testDevelopmentLineUsesCommit() {
        XCTAssertEqual(
            AppVersion.menuLine(info: ["GenieReleaseVersion": "", "GenieGitCommit": "abc1234"]),
            "バージョン: 開発版（abc1234）"
        )
    }

    func testMissingValuesProduceUnknownLine() {
        let cases: [[String: Any]?] = [nil, [:], ["GenieReleaseVersion": "", "GenieGitCommit": ""]]
        for info in cases {
            XCTAssertEqual(AppVersion.menuLine(info: info), "バージョン: 不明")
        }
    }

    func testReleaseRequiresAValidCommit() {
        let invalidCommits: [Any?] = [nil, "", "ABC1234", "abc123", "abc12345", " abc1234"]
        for commit in invalidCommits {
            var info: [String: Any] = ["GenieReleaseVersion": "1.1.0"]
            if let commit {
                info["GenieGitCommit"] = commit
            }
            XCTAssertEqual(AppVersion.menuLine(info: info), "バージョン: 不明")
        }
    }

    func testReleaseRejectsInvalidVersionText() {
        for version in ["v1.1.0", "1.1", "1.1.0-rc1", "1.1.0 "] {
            XCTAssertEqual(
                AppVersion.menuLine(info: ["GenieReleaseVersion": version, "GenieGitCommit": "fe7cf02"]),
                "バージョン: 不明"
            )
        }
    }

    func testWrongPlistValueTypesProduceUnknownLine() {
        XCTAssertEqual(
            AppVersion.menuLine(info: ["GenieReleaseVersion": "1.1.0", "GenieGitCommit": 1_234_567]),
            "バージョン: 不明"
        )
        XCTAssertEqual(
            AppVersion.menuLine(info: ["GenieReleaseVersion": true, "GenieGitCommit": "fe7cf02"]),
            "バージョン: 不明"
        )
    }

    func testTemplateHasEmptyVersionKeys() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("AppBundle/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(info["GenieReleaseVersion"] as? String, "")
        XCTAssertEqual(info["GenieGitCommit"] as? String, "")
        XCTAssertEqual(AppVersion.menuLine(info: info), "バージョン: 不明")
    }

    func testMenuShowsOneDisabledVersionRowBetweenTitleAndPhase() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/GenieMenuBarApp.swift"), encoding: .utf8)
        let populate = try XCTUnwrap(source.components(separatedBy: "private func populate(_ menu: NSMenu) {").dropFirst().first)
        let rows = populate
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let titleIndex = try XCTUnwrap(rows.firstIndex(of: "label(\"ジーニー\")"))
        XCTAssertEqual(rows[titleIndex + 1], "label(menuVersionLine)")
        XCTAssertEqual(rows[titleIndex + 2], "label(phase)")
        XCTAssertTrue(source.contains("private let menuVersionLine = AppVersion.menuLine(info: Bundle.main.infoDictionary)"))
        XCTAssertEqual(source.components(separatedBy: "AppVersion.menuLine(info: Bundle.main.infoDictionary)").count - 1, 1)
        XCTAssertTrue(source.contains("NSMenuItem(title: title, action: nil, keyEquivalent: \"\")"))
        XCTAssertTrue(source.contains("item.isEnabled = false"))
    }
}
