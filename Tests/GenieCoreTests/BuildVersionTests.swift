import Foundation
import XCTest
@testable import GenieCore

final class BuildVersionTests: XCTestCase {
    func testHeadReleaseTagsChooseHighestSemanticVersion() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["-C", repo.path, "tag", "v1.0.0"])
        try git(["-C", repo.path, "tag", "v1.1.0"])
        try git(["-C", repo.path, "tag", "macmini-2026-11-05"])

        let result = try runBuildVersion(repo: repo)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "release=1.1.0\ncommit=\(try headPrefix(repo))\n")
        XCTAssertTrue(result.error.isEmpty)
    }

    func testDeploymentTagDoesNotBecomeARelease() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["-C", repo.path, "tag", "macmini-2026-11-05"])

        let result = try runBuildVersion(repo: repo)
        XCTAssertEqual(result.output, "release=\ncommit=\(try headPrefix(repo))\n")
    }

    func testTagOnAnEarlierCommitIsNotUsed() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["-C", repo.path, "tag", "v1.1.0"])
        try Data("next\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try git(["-C", repo.path, "add", "tracked.txt"])
        try git(["-C", repo.path, "commit", "-q", "-m", "next"])

        let result = try runBuildVersion(repo: repo)
        XCTAssertEqual(result.output, "release=\ncommit=\(try headPrefix(repo))\n")
    }

    func testTrackedChangesClearReleaseButUntrackedFilesDoNot() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["-C", repo.path, "tag", "v1.1.0"])
        try Data("untracked\n".utf8).write(to: repo.appendingPathComponent("new.txt"))

        let untracked = try runBuildVersion(repo: repo)
        XCTAssertEqual(untracked.output, "release=1.1.0\ncommit=\(try headPrefix(repo))\n")

        try Data("changed\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        let tracked = try runBuildVersion(repo: repo)
        XCTAssertEqual(tracked.output, "release=\ncommit=\(try headPrefix(repo))\n")
    }

    func testMissingGitAndNonRepositoryReturnEmptyFieldsAndOneWarning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let nonRepository = try runBuildVersion(repo: directory)
        XCTAssertEqual(nonRepository.status, 0)
        XCTAssertEqual(nonRepository.output, "release=\ncommit=\n")
        XCTAssertEqual(nonRepository.error, "warning: Git metadata unavailable\n")

        let noGit = try runBuildVersion(repo: directory, path: "/no-git")
        XCTAssertEqual(noGit.status, 0)
        XCTAssertEqual(noGit.output, "release=\ncommit=\n")
        XCTAssertEqual(noGit.error, "warning: Git metadata unavailable\n")
    }

    private func makeRepository() throws -> URL {
        let repo = try temporaryDirectory()
        try git(["-C", repo.path, "init", "-q"])
        try git(["-C", repo.path, "config", "user.name", "test"])
        try git(["-C", repo.path, "config", "user.email", "test@example.com"])
        try Data("tracked\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try git(["-C", repo.path, "add", "tracked.txt"])
        try git(["-C", repo.path, "commit", "-q", "-m", "initial"])
        return repo
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menu-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func headPrefix(_ repo: URL) throws -> String {
        String(try git(["-C", repo.path, "rev-parse", "HEAD"]).prefix(7))
    }

    private func git(_ arguments: [String]) throws -> String {
        try run(executable: "/usr/bin/env", arguments: ["git"] + arguments).output
    }

    private func runBuildVersion(repo: URL, path: String? = nil) throws -> (status: Int32, output: String, error: String) {
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        return try run(
            executable: "/bin/sh",
            arguments: [repoRoot().appendingPathComponent("scripts/build-version.sh").path, repo.path],
            environment: environment
        )
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
