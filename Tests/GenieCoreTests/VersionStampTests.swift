import Foundation
import XCTest
@testable import GenieCore

final class VersionStampTests: XCTestCase {
    func testReleaseStampWritesGenieAndBundleVersionsToTargetFile() throws {
        let template = repoRoot().appendingPathComponent("AppBundle/Info.plist")
        let original = try Data(contentsOf: template)
        let target = try copiedTemplate()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        try stamp(target, release: "1.1.0", commit: "fe7cf02")

        let info = try readPlist(target)
        XCTAssertEqual(info["GenieReleaseVersion"] as? String, "1.1.0")
        XCTAssertEqual(info["GenieGitCommit"] as? String, "fe7cf02")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.1.0")
        XCTAssertEqual(try Data(contentsOf: template), original)
    }

    func testDevelopmentStampKeepsTemplateBundleVersion() throws {
        let template = repoRoot().appendingPathComponent("AppBundle/Info.plist")
        let original = try Data(contentsOf: template)
        let target = try copiedTemplate()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        try stamp(target, release: "", commit: "abc1234")

        let info = try readPlist(target)
        XCTAssertEqual(info["GenieReleaseVersion"] as? String, "")
        XCTAssertEqual(info["GenieGitCommit"] as? String, "abc1234")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.1.0")
        XCTAssertEqual(try Data(contentsOf: template), original)
    }

    func testAssemblyStampsStagedPlistBeforeSigning() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("scripts/assemble-app.sh"), encoding: .utf8)
        let copy = try XCTUnwrap(source.range(of: "cp \"${ROOT}/AppBundle/Info.plist\" \"${app}/Contents/Info.plist\""))
        let buildVersion = try XCTUnwrap(source.range(of: "build-version.sh\" \"${ROOT}"))
        let stamp = try XCTUnwrap(source.range(of: "stamp-version.py"))
        let signing = try XCTUnwrap(source.range(of: "codesign --force"))
        XCTAssertLessThan(copy.lowerBound, buildVersion.lowerBound)
        XCTAssertLessThan(buildVersion.lowerBound, stamp.lowerBound)
        XCTAssertLessThan(stamp.lowerBound, signing.lowerBound)
        XCTAssertTrue(source.contains("\"${app}/Contents/Info.plist\""))
        XCTAssertFalse(source.contains("plutil"))
    }

    private func copiedTemplate() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menu-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("Info.plist")
        try FileManager.default.copyItem(at: repoRoot().appendingPathComponent("AppBundle/Info.plist"), to: target)
        return target
    }

    private func stamp(_ path: URL, release: String, commit: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            repoRoot().appendingPathComponent("scripts/stamp-version.py").path,
            path.path,
            release,
            commit,
        ]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }
}
