import Foundation
import XCTest
@testable import GenieCore

final class JobMenuStateTests: XCTestCase {
    func testSnapshotDistinguishesEmptyAndInvalidJobURLs() async throws {
        let cases: [(String, JobRouteState, String)] = [
            ("", .fallback, "Job Engine の URL が空なので通常の webhook に送ります"),
            ("http://example.com/", .invalid, "Job Engine の URL が使えない形なので送りません")
        ]
        for (url, state, line) in cases {
            let h = Harness()
            h.config.jobChatIDs = [7]
            h.config.jobWebhookURL = url
            let engine = try await h.opened()
            let snapshot = await engine.snapshot()
            XCTAssertEqual(snapshot.jobRouteState, state)
            XCTAssertEqual(snapshot.jobRouteState.menuLine, line)
            XCTAssertFalse(snapshot.jobWebhookConfigured)
        }
    }

    func testSnapshotHasNoJobWarningWithoutJobChatsOrWithValidJobURL() async throws {
        let cases: [([Int64], String, JobRouteState)] = [
            ([], "", .ordinary),
            ([], "http://example.com/", .ordinary),
            ([], "http://127.0.0.1:3321/ingress/genie", .ordinary),
            ([7], "http://127.0.0.1:3321/ingress/genie", .job)
        ]
        for (chats, url, state) in cases {
            let h = Harness()
            h.config.jobChatIDs = chats
            h.config.jobWebhookURL = url
            let engine = try await h.opened()
            let snapshot = await engine.snapshot()
            XCTAssertEqual(snapshot.jobRouteState, state)
            XCTAssertNil(snapshot.jobRouteState.menuLine)
            XCTAssertEqual(snapshot.jobWebhookConfigured, !chats.isEmpty)
        }
    }

    func testMenuUsesSnapshotWithoutReloadingConfig() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/GenieMenuBar/GenieMenuBarApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("snapshot?.jobRouteState.menuLine"))
        XCTAssertFalse(source.contains("ConfigLoader.load(from: paths.configFile)"))
    }
}
