import XCTest
@testable import GenieCore

final class EngineWatchTests: XCTestCase {
    func testSelfChatDoubleRecordNFDAndMarker() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        let engine = try await harness.opened()
        let fixture = repoRoot().appendingPathComponent("Tests/GenieCoreTests/Fixtures/self-chat.ndjson")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            _ = await engine.ingestWatchLine(String(line))
        }
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        let body = try decodedWebhookText(harness.webhook.bodies[0])
        XCTAssertEqual(
            Array(body.unicodeScalars.map(\.value)),
            [0x1FA94, 0x20, 0x3067]
        )
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 103)
        XCTAssertTrue(harness.state.deadLetters.isEmpty)
        assertNoBody(harness, "\u{3066}\u{3099}")
        assertNoBody(harness, "\u{3067}")
    }

    func testCreatedAtIsNotTheIdempotencyKey() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        let engine = try await harness.opened()
        let created = "2026-10-26T01:00:00.000Z"
        _ = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "a", chat: 1, fromMe: true, text: "\u{1FA94} one", created: created
        ))
        _ = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "b", chat: 1, fromMe: true, text: "\u{1FA94} two", created: created
        ))
        XCTAssertEqual(harness.webhook.bodies.count, 2)
    }

    func testFalseSideCanArriveFirstAndIsIgnored() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        let engine = try await harness.opened()
        let text = "\u{1FA94}\u{FE0F} hi"
        let first = await engine.ingestWatchLine(watchLine(
            id: 10, guid: "in", chat: 7, fromMe: false, text: text, created: "2026-10-26T01:00:00.074Z"
        ))
        let second = await engine.ingestWatchLine(watchLine(
            id: 11, guid: "out", chat: 7, fromMe: true, text: text, created: "2026-10-26T01:00:00.000Z"
        ))
        XCTAssertEqual(first, .ignoredNotFromMe)
        XCTAssertEqual(second, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 11)
    }

    func testCursorDoesNotRewindOrMoveForEdits() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        let engine = try await harness.opened()
        _ = await engine.ingestWatchLine(watchLine(id: 50, guid: "n", chat: 1, fromMe: true, text: "plain"))
        _ = await engine.ingestWatchLine(watchLine(id: 40, guid: "older", chat: 1, fromMe: true, text: "older"))
        _ = await engine.ingestWatchLine(watchLine(
            id: 90, guid: "edit", chat: 1, fromMe: true, text: "\u{1FA94} later", type: "edited"
        ))
        _ = await engine.ingestWatchLine(watchLine(
            id: 12, guid: "unsent", chat: 1, fromMe: true, text: "", type: "unsent"
        ))
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 50)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
    }

    func testGuidIdempotencyAndSentGuidAndFingerprint() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        let text = "\u{1FA94} ping"
        let hash = SHA256.hex(Data(TextNormalizer.nfc(text).utf8))
        harness.state.state.sentGUIDs = ["echo-guid"]
        harness.state.state.fingerprints = [
            SentFingerprint(hash: hash, sentAt: harness.clock.current),
        ]
        let engine = try await harness.opened()
        let duplicate = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "echo-guid", chat: 1, fromMe: true, text: text
        ))
        XCTAssertEqual(duplicate, .ignoredSentGUID)
        let fingerprinted = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "fresh", chat: 1, fromMe: true, text: text,
            created: "2023-11-14T22:13:20Z"
        ))
        XCTAssertEqual(fingerprinted, .ignoredFingerprint)
        let again = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "fresh", chat: 1, fromMe: true, text: text
        ))
        XCTAssertEqual(again, .duplicate)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
    }

    func testAllowlistDefaultsOffAndStillAdvancesCursor() async throws {
        let harness = Harness()
        let engine = try await harness.opened()
        let result = await engine.ingestWatchLine(watchLine(
            id: 8, guid: "g", chat: 3, fromMe: true, text: "\u{1FA94} no"
        ))
        XCTAssertEqual(result, .ignoredNotAllowed)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 8)
        XCTAssertEqual(snap.enabledChatIDs, [])
    }

    func testPausedIngestDoesNotAdvance() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        let engine = try await harness.opened()
        await engine.setPaused(true)
        let result = await engine.ingestWatchLine(watchLine(
            id: 4, guid: "g", chat: 1, fromMe: true, text: "\u{1FA94} wait"
        ))
        XCTAssertEqual(result, .deferredPaused)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 0)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
    }

    func testReactionAndMissingFromMeAreNotTriggers() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        let engine = try await harness.opened()
        _ = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "tap", chat: 1, fromMe: true, text: "\u{1FA94}", reaction: true
        ))
        _ = await engine.ingestWatchLine(#"{"id":2,"guid":"anon","chat_id":1,"text":"\uD83E\uDE94 hi"}"#)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursorRowID, 2)
    }

    func testReplyPrefixDoesNotCallAgain() async throws {
        let harness = Harness()
        harness.allow.ids = [1]
        let engine = try await harness.opened()
        let reply = GenieConfig.productDefaults.marker + " hi"
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "echo", chat: 1, fromMe: true, text: reply
        ))
        XCTAssertEqual(result, .ignoredReplyMarker)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        XCTAssertFalse(Signal.matches(reply))
    }

    func testNotJSONDoesNotLogTheLine() async throws {
        let harness = Harness()
        let engine = try await harness.opened()
        let result = await engine.ingestWatchLine("this-is-not-json")
        XCTAssertEqual(result, .notJSON)
        assertNoBody(harness, "this-is-not-json")
        XCTAssertEqual(harness.log.records.map(\.code), ["watch_not_json"])
    }
}
