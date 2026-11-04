import Foundation
import XCTest
@testable import GenieCore

extension XCTestCase {
    func splitHarness(_ text: String = "こんにちは", id: String = "r1", chat: Int64 = 7, origin: String = "origin") -> Harness {
        let harness = Harness()
        harness.allow.ids = [chat]
        harness.config.replyFetchURL = "https://example.com/replies"
        seedRoute(harness, guid: origin, chat: chat)
        harness.replies.pages = [ReplyPage(replies: [routedReply(id, chat: chat, text: text, guid: origin)], nextCursor: nil)]
        return harness
    }

    func splitOpened(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async -> GenieEngine? {
        do { return try await harness.opened() }
        catch { XCTFail("Harness.opened failed: \(error)", file: file, line: line); return nil }
    }

    func splitJSON(_ state: PersistedState, file: StaticString = #filePath, line: UInt = #line) -> [String: Any]? {
        do {
            let data = try StateCoding.encoder().encode(state)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("PersistedState JSON was not an object", file: file, line: line)
                return nil
            }
            return object
        } catch { XCTFail("PersistedState encode failed: \(error)", file: file, line: line); return nil }
    }

    func splitRoundTrip(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> PersistedState? {
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            return try StateCoding.decoder().decode(PersistedState.self, from: data)
        } catch { XCTFail("PersistedState decode failed: \(error)", file: file, line: line); return nil }
    }

    func splitPartial(_ id: String, chat: Int64 = 7, markerGUID: String = "sent-1", at: Double = 1_700_000_000_000, resends: Int = 0) -> [String: Any] {
        ["reply_id": id, "chat_id": chat, "marker_guid": markerGUID, "at": at, "body_resends": resends]
    }

    func splitInstallPartials(_ harness: Harness, _ partials: [[String: Any]], pending: [[String: Any]] = [], file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard var json = splitJSON(harness.state.state, file: file, line: line) else { return false }
        json["partial_replies"] = partials
        if !pending.isEmpty { json["pending_sends"] = pending }
        guard let decoded = splitRoundTrip(json, file: file, line: line) else { return false }
        harness.state.state = decoded
        return true
    }
}
