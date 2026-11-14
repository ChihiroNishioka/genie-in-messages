import Foundation
import XCTest
@testable import GenieCore

final class GroupPrivacyRegressionTests: XCTestCase {
    let group = "iMessage;+;chat000000000000000001"
    let marker = "🕊️"

    func configured(_ extra: [String: Any] = [:]) throws -> GenieConfig {
        var values: [String: Any] = ["group_chat_guids": [group], "webhook_url": "https://127.0.0.1/webhook", "reply_fetch_url": "https://127.0.0.1/replies"]
        values.merge(extra) { _, rhs in rhs }
        return try JSONDecoder().decode(GenieConfig.self, from: JSONSerialization.data(withJSONObject: values))
    }

    func engine(_ h: Harness, _ p: MutableConfig) throws -> GenieEngine {
        try GenieEngine(configProvider: p, initialConfig: p.config, stateStore: h.state,
            allowlistStore: h.allow, replySource: h.replies, sender: h.sender, webhook: h.webhook,
            secrets: h.secrets, lock: h.lock, clock: h.clock, log: h.log)
    }

    func list(_ group: Bool = true) -> [ChatSummary] {
        [ChatSummary(id: 42, title: "room", isGroup: group, guid: group ? self.group : "direct")]
    }

    func line(_ id: Int = 1, fromMe: Bool = false, text: String = "🪔 private request", guid: String? = nil, sender: String = " FAMILY@EXAMPLE.COM ") -> String {
        watchLine(id: id, guid: "privacy-incoming-\(id)", chat: 42, fromMe: fromMe, text: text,
            chatGUID: guid ?? group, sender: sender, isGroup: true)
    }

    func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testGC15NoHandleBodyMarkerOrConfigTableLeaksAcrossDeliveryFailureAndReply() async throws {
        for mode in 0..<12 {
            let phone = mode >= 6
            let mode = mode % 6
            let h = Harness()
            let failureMode = mode % 3
            let job = mode >= 3
            h.secrets = StaticSecret(webhook: "hook-secret", reply: nil, job: "job-secret")
            let p = MutableConfig(try configured(["reply_marker": marker, "webhook_url": failureMode == 2 ? "" : "https://127.0.0.1/webhook",
                "job_chat_ids": job ? [42] : [], "job_webhook_url": job ? "http://127.0.0.1/job" : ""]))
            if failureMode == 1 { h.webhook.results = [.success(WebhookHTTPResult(statusCode: 400))] }
            let e = try engine(h, p)
            await e.showChats(list())
            let result = await e.ingestWatchLine(line(sender: phone ? " +1 555 010 0000 " : " FAMILY@EXAMPLE.COM "))
            XCTAssertEqual(result, (job && failureMode == 2) || failureMode == 0 ? .delivered : .deadLettered(failureMode == 1 ? "webhook_http_400" : "webhook_not_configured"))
            if failureMode == 0 || (job && failureMode == 2) {
                h.replies.pages = [ReplyPage(replies: [routedReply("privacy-reply", chat: 42, text: "private answer", guid: "privacy-incoming-1")], nextCursor: nil)]
                _ = await e.pollReplies()
                XCTAssertEqual(h.sender.sent.map(\.text), [marker, "private answer"])
            } else {
                XCTAssertEqual(h.state.deadLetters.count, 1)
                if job {
                    XCTAssertEqual(h.webhook.bodies.count, 1)
                    XCTAssertEqual(h.state.deadLetters.first?.kind, "job_webhook")
                    XCTAssertEqual(h.state.deadLetters.first?.error, "webhook_http_400")
                    XCTAssertEqual(h.state.deadLetters.first?.attempts, 1)
                }
            }
            let log = String(decoding: try JSONEncoder().encode(h.log.records), as: UTF8.self)
            let state = String(decoding: try StateCoding.encoder().encode(h.state.state), as: UTF8.self)
            let letters = String(decoding: try JSONEncoder().encode(h.state.deadLetters), as: UTF8.self)
            let snapshot = String(describing: await e.snapshot())
            let rows = AllowlistOrdering.rows(chats: list(), enabledIDs: [], query: "", configIDs: [42])
            let menu = rows.map { "\($0.title) \($0.kindLabel)" }.joined(separator: "\n")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let allowURL = folder.appendingPathComponent("allowlist.json")
            try FileAllowlistStore(file: allowURL).save(h.allow.load())
            let allow = try String(contentsOf: allowURL, encoding: .utf8)
            for value in [" +1 555 010 0000 ", "+15550100000", "tel:", " FAMILY@EXAMPLE.COM ", "email:family@example.com", "family@example.com", "🪔 private request", "private answer", marker] {
                for output in [log, state, letters, snapshot, menu, allow] {
                    XCTAssertFalse(output.contains(value), "private value appeared outside payload or send")
                }
            }
            for output in [log, state, letters, snapshot, menu, allow] { XCTAssertFalse(output.contains("sender_handle")) }
            if job && failureMode != 2 {
                XCTAssertEqual(try json(XCTUnwrap(h.webhook.bodies.first))["sender_handle"] as? String, phone ? "tel:+15550100000" : "email:family@example.com")
            }
            for output in [log, snapshot, menu, allow] { XCTAssertFalse(output.contains(group)) }
            for output in [state, letters, allow] {
                XCTAssertFalse(output.contains("group_chat_guids"))
                XCTAssertFalse(output.contains("configGroups"))
                XCTAssertFalse(output.contains("sender_handle"))
            }
            XCTAssertTrue(h.allow.ids.isEmpty)
            XCTAssertEqual(h.state.state.knownChats.map(\.guid), [group])
        }
    }

    func testGC17InvalidWarningIsGatedResolvedAndRearmedWithoutValue() async throws {
        let h = Harness()
        let p = MutableConfig(try configured(["reply_marker": "x🪔"]))
        let e = try engine(h, p)
        _ = await e.ingestWatchLine("")
        _ = await e.ingestWatchLine("")
        XCTAssertEqual(h.log.records.filter { $0.code == "reply_marker_invalid" }.count, 1)
        p.config = try configured(["reply_marker": marker])
        _ = await e.ingestWatchLine("")
        p.config = try configured(["reply_marker": "x🪔"])
        _ = await e.ingestWatchLine("")
        XCTAssertEqual(h.log.records.filter { $0.code == "reply_marker_invalid" }.count, 2)
        p.config = try configured(["reply_marker": NSNull()])
        _ = await e.ingestWatchLine("")
        XCTAssertEqual(h.log.records.filter { $0.code == "reply_marker_invalid" }.count, 2)
        let logs = String(decoding: try JSONEncoder().encode(h.log.records), as: UTF8.self)
        XCTAssertFalse(logs.contains("x🪔"))
        XCTAssertFalse(logs.contains(marker))
    }

    func testGC18CustomAndDefaultMarkersAreIgnoredForEverySenderAndSelfChat() async throws {
        for selfChat in [false, true] {
            let h = Harness()
            let p = MutableConfig(try configured(["reply_marker": marker, "self_chat_ids": selfChat ? [42] : []]))
            if selfChat { h.allow.ids = [42]; h.allow.guids[42] = group }
            let e = try engine(h, p)
            await e.showChats(list())
            var id = 0
            for fromMe in [false, true] {
                for prefix in [marker, "🕊", ReplyComposer.markerText, "🧞‍♂"] {
                    id += 1
                    let result = await e.ingestWatchLine(line(id, fromMe: fromMe, text: " \u{200B}" + prefix + " 🪔 ignored"))
                    XCTAssertEqual(result, .ignoredReplyMarker)
                }
            }
            XCTAssertTrue(h.webhook.bodies.isEmpty)
            let control = await e.ingestWatchLine(line(100, fromMe: true))
            XCTAssertEqual(control, .delivered)
            XCTAssertEqual(h.webhook.bodies.count, 1)
        }
    }

    func testGC22SelfChatWithUnrelatedGroupKeepsDefaultPayloadAndTwoPartReply() async throws {
        let h = Harness()
        let p = MutableConfig(try configured(["self_chat_ids": [42]]))
        h.allow.ids = [42]
        h.allow.guids[42] = "direct"
        let e = try engine(h, p)
        await e.showChats(list(false))
        let echo = await e.ingestWatchLine(line(1, guid: "direct"))
        XCTAssertEqual(echo, .ignoredNotFromMe)
        let mine = await e.ingestWatchLine(line(2, fromMe: true, guid: "direct"))
        XCTAssertEqual(mine, .delivered)
        XCTAssertEqual(h.webhook.bodies.count, 1)
        let body = try json(XCTUnwrap(h.webhook.bodies.first))
        XCTAssertEqual(body.count, 9)
        XCTAssertNil(body["sender_handle"])
        XCTAssertEqual(body["sender_name"] as? String, "me")
        h.replies.pages = [ReplyPage(replies: [routedReply("self-regression", chat: 42, text: "answer", guid: "privacy-incoming-2")], nextCursor: nil)]
        _ = await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
        XCTAssertEqual(h.sender.sent.map(\.chatID), [42, 42])
    }

    func testGC13OnlyConfigGroupOtherMemberGetsHandle() async throws {
        for mode in 0..<8 {
            let job = mode >= 4
            let mode = mode % 4
            let h = Harness()
            h.secrets = StaticSecret(webhook: "hook-secret", reply: nil, job: "job-secret")
            let p = MutableConfig(try configured(mode == 1 ? ["self_chat_ids": [42]] : [:]))
            if mode >= 2 {
                p.config.groupChatGUIDs = []
                h.allow.ids = [42]
                h.allow.guids[42] = mode == 3 ? "direct" : group
            }
            if job {
                p.config.jobChatIDs = [42]
                p.config.jobWebhookURL = "http://127.0.0.1/job"
            }
            let e = try engine(h, p)
            await e.showChats(mode == 3 ? [ChatSummary(id: 42, title: "direct", isGroup: false, guid: "direct",
                participants: ["family@example.com"], participantsKnown: true, lastAddressedHandle: "+1 555 010 0000")] : list())
            let event = mode == 3 ? watchLine(id: 1, guid: "privacy-incoming-1", chat: 42, fromMe: false,
                text: "🪔 private request", chatGUID: "direct", sender: "family@example.com", isGroup: false,
                participants: ["family@example.com"], destinationCallerID: "+1 555 010 0000") : line(fromMe: mode <= 1)
            let result = await e.ingestWatchLine(event)
            XCTAssertEqual(result, .delivered)
            let body = try json(XCTUnwrap(h.webhook.bodies.first))
            XCTAssertEqual(body.count, 9)
            XCTAssertNil(body["sender_handle"])
            if mode <= 1 { XCTAssertEqual(body["sender_name"] as? String, "me") }
        }
    }

    func testGNSH3JobSelfChatInboundEchoDoesNotSend() async throws {
        let h = Harness()
        h.secrets = StaticSecret(webhook: "hook-secret", reply: nil, job: "job-secret")
        let p = MutableConfig(try configured(["self_chat_ids": [42], "job_chat_ids": [42], "job_webhook_url": "http://127.0.0.1/job"]))
        let e = try engine(h, p)
        await e.showChats(list())
        let result = await e.ingestWatchLine(line())
        XCTAssertEqual(result, .ignoredNotFromMe)
        XCTAssertTrue(h.webhook.bodies.isEmpty)
    }

    func testConfiguredMarkerAlsoAppliesToSelfChatAndFingerprint() async throws {
        let h = Harness()
        let p = MutableConfig(try configured(["reply_marker": marker, "self_chat_ids": [42]]))
        h.allow.ids = [42]; h.allow.guids[42] = "direct"
        let e = try engine(h, p)
        await e.showChats(list(false))
        let result = await e.ingestWatchLine(line(fromMe: true, guid: "direct"))
        XCTAssertEqual(result, .delivered)
        h.replies.pages = [ReplyPage(replies: [routedReply("self-marker", chat: 42, text: "answer", guid: "privacy-incoming-1")], nextCursor: nil)]
        _ = await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [marker, "answer"])
        let echo = await e.ingestWatchLine(watchLine(id: 2, guid: "marker-echo", chat: 42, fromMe: true, text: marker, created: ISO8601.string(from: h.clock.current), chatGUID: "direct"))
        XCTAssertEqual(echo, .ignoredFingerprint)
    }
}
