import Foundation
import XCTest
@testable import GenieCore

final class OutboundPrivacyTests: XCTestCase {
    func testOB36OutboundLogsAndStateContainNoValues() async throws {
        let body = "outbound-private-body-0001"
        let invalidBody = "🪔 \(body)"

        let success = makePrivacyHarness(body: body)
        let successEngine = try await openPrivacyHarness(success)
        _ = await successEngine.pollOutbound()
        XCTAssertEqual(success.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text(body)])
        success.h.state.state = try reloaded(success.h.state.state).0
        let restarted = try success.engine(stop: StopSignal())
        await restarted.showChats(privacyChats())
        _ = await restarted.pollOutbound()
        XCTAssertEqual(success.h.sender.outgoing.count, 2)
        try assertOutboundPrivacy(success, body: body)

        let rejected = makePrivacyHarness(body: invalidBody)
        let rejectedEngine = try await openPrivacyHarness(rejected)
        _ = await rejectedEngine.pollOutbound()
        XCTAssertTrue(rejected.h.sender.outgoing.isEmpty)
        XCTAssertEqual(rejected.h.state.state.outbound.records.first?.terminalCode, "outbound_signal_body")
        try assertOutboundPrivacy(rejected, body: invalidBody)

        let failedSend = makePrivacyHarness(body: body)
        failedSend.h.sender.script = [
            .success(SendReceipt(id: 1, guid: "marker-private-0001", status: "sent")),
            .failure(.failed),
        ]
        let failedSendEngine = try await openPrivacyHarness(failedSend)
        _ = await failedSendEngine.pollOutbound()
        XCTAssertEqual(failedSend.h.state.deadLetters.last?.error, "outbound_body_send_failed")
        try assertOutboundPrivacy(failedSend, body: body)

        let held = makePrivacyHarness(body: body)
        let heldEngine = try await openPrivacyHarness(held)
        _ = await heldEngine.applyChatList(.parsed(ChatListParse(chats: privacyChats(), failedLineCount: 1)))
        _ = await heldEngine.pollOutbound()
        XCTAssertTrue(held.h.sender.outgoing.isEmpty)
        XCTAssertTrue(held.h.log.records.contains { $0.code == "outbound_held_unverified" })
        try assertOutboundPrivacy(held, body: body)

        let failedSave = makePrivacyHarness(body: body)
        let failedSaveEngine = try await openPrivacyHarness(failedSave)
        failedSave.h.state.shouldFailSave = true
        _ = await failedSaveEngine.pollOutbound()
        XCTAssertTrue(failedSave.h.sender.outgoing.isEmpty)
        XCTAssertTrue(failedSave.h.log.records.contains { $0.code == "outbound_state_save_failed" })
        try assertOutboundPrivacy(failedSave, body: body)

        let interrupted = makePrivacyHarness(body: body)
        var durable: PersistedState?
        interrupted.h.sender.onSendFile = {
            durable = interrupted.h.state.state
            interrupted.h.stop.stop()
        }
        let interruptedEngine = try await openPrivacyHarness(interrupted)
        _ = await interruptedEngine.pollOutbound()
        XCTAssertEqual(interrupted.h.sender.outgoing.count, 1)
        interrupted.h.sender.onSendFile = nil
        interrupted.h.state.state = try XCTUnwrap(durable)
        let interruptedRestart = try interrupted.engine(stop: StopSignal())
        await interruptedRestart.showChats(privacyChats())
        _ = await interruptedRestart.pollOutbound()
        XCTAssertEqual(interrupted.h.sender.outgoing.count, 1)
        try assertOutboundPrivacy(interrupted, body: body)
    }

    private func makePrivacyHarness(body: String) -> OutboundHarness {
        let f = OutboundHarness()
        f.provider.config.outboundTargets["self"] = Self.privateGUID
        f.provider.config.selfChatIDs = []
        f.h.allow.guids[8] = Self.privateGUID
        f.h.sender.script = [
            .success(SendReceipt(id: 1, guid: Self.markerGUID, status: "sent")),
            .success(SendReceipt(id: 2, guid: Self.bodyGUID, status: "sent")),
        ]
        f.source.entries = [f.row(Self.pageID, key: Self.key, target: .self, text: body)]
        return f
    }

    private func openPrivacyHarness(_ f: OutboundHarness) async throws -> GenieEngine {
        let engine = try f.engine()
        await engine.showChats(privacyChats())
        return engine
    }

    private func privacyChats() -> [ChatSummary] {
        [
            ChatSummary(id: 7, title: "family", isGroup: true, guid: OutboundHarness.family),
            ChatSummary(
                id: 8,
                title: "self",
                isGroup: false,
                guid: Self.privateGUID,
                participants: [Self.privateHandle],
                participantsKnown: true,
                lastAddressedHandle: Self.privateHandle
            ),
        ]
    }

    private func assertOutboundPrivacy(_ f: OutboundHarness, body: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let logJSON = try json(f.h.log.records)
        let deadLetterJSON = try json(f.h.state.deadLetters)
        let outboundJSON = try json(f.h.state.state.outbound)
        let rawValues = [body, Self.privateGUID, Self.privateHandle, Self.markerGUID, Self.bodyGUID, Self.pageID, Self.key,
                         f.provider.config.outboundNotionDataSourceID, expectedGIFPath()]

        for value in rawValues {
            XCTAssertFalse(logJSON.contains(value), "outbound logs contain a private value", file: file, line: line)
            XCTAssertFalse(deadLetterJSON.contains(value), "outbound deadletters contain a private value", file: file, line: line)
            XCTAssertFalse(outboundJSON.contains(value), "outbound JSON contains a raw private value", file: file, line: line)
        }

        let sourceHash = OutboundHash.digest(kind: "source", values: [NotionDataSourceID.canonical(f.provider.config.outboundNotionDataSourceID)!])
        let pageHash = OutboundHash.digest(kind: "page", values: [Self.pageID])
        let keyHash = OutboundHash.digest(kind: "key", values: [Self.key])
        let signatureHash = OutboundHash.digest(kind: "signature", values: ["self", body.precomposedStringWithCanonicalMapping])
        let destinationHash = OutboundHash.digest(kind: "destination", values: [Self.privateGUID])
        let bodyHash = OutboundHash.digest(kind: "body", values: [body.precomposedStringWithCanonicalMapping])
        let deliveryHash = OutboundHash.digest(kind: "delivery", values: [sourceHash, pageHash])
        let hashes = [sourceHash, pageHash, keyHash, signatureHash, destinationHash, bodyHash,
                      deliveryHash, "outbound:\(deliveryHash)"]
        for hash in hashes {
            XCTAssertFalse(logJSON.contains(hash), "outbound logs contain a hash", file: file, line: line)
            XCTAssertFalse(deadLetterJSON.contains(hash), "outbound deadletters contain a hash", file: file, line: line)
        }

        let outboundLogs = f.h.log.records.filter { $0.code.hasPrefix("outbound_") || $0.code == "reply_sent" }
        XCTAssertFalse(outboundLogs.isEmpty, file: file, line: line)
        for record in outboundLogs {
            XCTAssertNil(record.chatID, file: file, line: line)
            XCTAssertNil(record.guid, file: file, line: line)
            XCTAssertNil(record.rowid, file: file, line: line)
            XCTAssertNil(record.detail, file: file, line: line)
        }
        for entry in f.h.state.deadLetters where entry.kind == "outbound" {
            XCTAssertNil(entry.chatID, file: file, line: line)
            XCTAssertNil(entry.guid, file: file, line: line)
            XCTAssertNil(entry.rowid, file: file, line: line)
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8)!
    }

    private static let privateGUID = "iMessage;-;private-chat-guid"
    private static let privateHandle = "000000000001"
    private static let markerGUID = "marker-private-0001"
    private static let bodyGUID = "body-private-0001"
    private static let pageID = "page-private-0001"
    private static let key = "key-private-0001"

    func testOB23BodyValidation() async throws {
        let cases: [(String, String)] = [
            ("", "outbound_empty_body"),
            ("🧞‍♂️", "outbound_empty_body"),
            ("🪔 notice", "outbound_signal_body"),
            (" \u{200B}\u{FE0F}🪔 notice", "outbound_signal_body"),
            ("\0", "outbound_text_invalid"),
            (String(repeating: "a", count: 8001), "outbound_text_invalid"),
        ]
        for (i, testCase) in cases.enumerated() {
            let (text, code) = testCase
            let f = OutboundHarness(); f.source.entries = [f.row("page-\(i)", text: text)]
            let e = try await f.opened(); _ = await e.pollOutbound()
            XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
            XCTAssertTrue(f.h.log.records.contains { $0.code == code }, code)
        }
    }
}
