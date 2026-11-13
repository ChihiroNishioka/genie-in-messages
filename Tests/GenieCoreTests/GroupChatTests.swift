import Foundation
import XCTest
@testable import GenieCore

final class GroupChatTests: XCTestCase {
    let group = "iMessage;+;chat000000000000000001"
    let other = "iMessage;+;chat000000000000000002"

    func setup(menu: Bool = false, groups: [String]? = nil) throws -> (Harness, MutableConfig, GenieEngine) {
        let h = Harness()
        h.secrets = StaticSecret(webhook: "hook-secret", reply: nil, job: "job-secret")
        let data = try JSONSerialization.data(withJSONObject: [
            "group_chat_guids": groups ?? [group],
            "webhook_url": "https://127.0.0.1/webhook",
            "reply_fetch_url": "https://127.0.0.1/replies"
        ])
        let cfg = try JSONDecoder().decode(GenieConfig.self, from: data)
        let provider = MutableConfig(cfg)
        if menu { h.allow.ids = [42]; h.allow.guids[42] = group }
        let e = try GenieEngine(configProvider: provider, initialConfig: cfg, stateStore: h.state,
            allowlistStore: h.allow, replySource: h.replies, sender: h.sender, webhook: h.webhook,
            secrets: h.secrets, lock: h.lock, clock: h.clock, log: h.log)
        return (h, provider, e)
    }

    func chats(_ id: Int64 = 42, guid: String? = nil, isGroup: Bool = true) -> [ChatSummary] {
        [ChatSummary(id: id, title: "room", isGroup: isGroup, guid: guid ?? group)]
    }

    func input(_ id: Int = 1, chat: Int = 42, guid: String? = nil, fromMe: Bool = false,
               sender: String = "family@example.com", text: String = "🪔 request") -> String {
        watchLine(id: id, guid: "incoming-\(id)", chat: chat, fromMe: fromMe, text: text,
                  chatGUID: guid ?? group, sender: sender, isGroup: true)
    }

    func receive(_ e: GenieEngine, _ line: String) async -> IngestResult {
        await e.ingestWatchLine(line)
    }

    func payload(_ h: Harness, at index: Int = 0) throws -> [String: Any] {
        guard h.webhook.bodies.indices.contains(index) else { XCTFail("webhook missing"); return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: h.webhook.bodies[index]) as? [String: Any])
    }

    func reply(_ h: Harness, id: String = "reply", origin: String = "incoming-1", chat: Int64 = 42) {
        h.replies.pages = [ReplyPage(replies: [routedReply(id, chat: chat, text: "answer", guid: origin)], nextCursor: nil)]
    }

    func testConfigIntentLocksSnapshotRowsUntilRemovedAcrossDirectoryChanges() async throws {
        for changedGUID in [false, true] {
            let (_, p, e) = try setup(menu: true)
            await e.showChats(chats())
            let changed = changedGUID ? chats(guid: other) : []
            await e.showChats(changed)
            let snapshot = await e.snapshot()
            let rows = AllowlistOrdering.rows(chats: changed, enabledIDs: Set(snapshot.enabledChatIDs),
                query: "", configIDs: Set(snapshot.configChatIDs))
            XCTAssertEqual(snapshot.configChatIDs, [42])
            XCTAssertEqual(rows.first { $0.id == 42 }?.kindLabel, "グループ（設定）")
            XCTAssertEqual(rows.first { $0.id == 42 }?.configLocked, true)
            p.config.groupChatGUIDs = []
            _ = await e.ingestWatchLine("")
            let removed = await e.snapshot()
            let unlocked = AllowlistOrdering.rows(chats: changed, enabledIDs: Set(removed.enabledChatIDs),
                query: "", configIDs: Set(removed.configChatIDs))
            XCTAssertTrue(removed.configChatIDs.isEmpty)
            XCTAssertFalse(unlocked.first { $0.id == 42 }?.configLocked ?? false)
        }
    }

    func testConfigLockedEngineMutationsLeaveMenuPermissionUntouched() async throws {
        for menu in [false, true] {
            let (h, _, e) = try setup(menu: menu)
            await e.showChats(chats())
            for operation in 0..<3 {
                if operation == 0 { await e.toggleChat(id: 42, guid: group) }
                else { await e.setChatEnabled(42, guid: other, enabled: operation == 1) }
                XCTAssertEqual(h.allow.ids, menu ? [42] : [])
                XCTAssertEqual(h.allow.guids[42], menu ? group : nil)
            }
            let result = await receive(e, input())
            XCTAssertEqual(result, .delivered)
            XCTAssertTrue(h.log.records.contains { $0.code == "allowlist_off_config_locked" })
        }
    }

    func testConfigOnlyGroupIsNeverWrittenToAllowlistFile() async throws {
        let (h, p, _) = try setup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("allowlist.json")
        let store = FileAllowlistStore(file: file)
        try store.save(.empty)
        let before = try Data(contentsOf: file)
        let e = try GenieEngine(configProvider: p, initialConfig: p.config, stateStore: h.state,
            allowlistStore: store, replySource: h.replies, sender: h.sender, webhook: h.webhook,
            secrets: h.secrets, lock: h.lock, clock: h.clock, log: h.log)
        await e.showChats(chats())
        await e.toggleChat(id: 42, guid: group)
        XCTAssertEqual(try Data(contentsOf: file), before)
        await e.setChatEnabled(42, guid: group, enabled: true)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(try store.load().isEmpty)
        let result = await receive(e, input())
        XCTAssertEqual(result, .delivered)
    }

    func testRemovingConfigThenTurningMenuOffStopsReceiving() async throws {
        let (h, p, e) = try setup(menu: true)
        await e.showChats(chats())
        let first = await receive(e, input())
        XCTAssertEqual(first, .delivered)
        p.config.groupChatGUIDs = []
        await e.setChatEnabled(42, enabled: false)
        let stopped = await receive(e, input(2))
        XCTAssertEqual(stopped, .ignoredNotAllowed)
        XCTAssertEqual(h.webhook.bodies.count, 1)
        XCTAssertTrue(h.allow.ids.isEmpty)
    }

    func testGC04ConfigOnlyGroupDeliversAndRepliesToSameChat() async throws {
        let (h, _, e) = try setup()
        await e.showChats(chats())
        let result = await receive(e, input())
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.webhook.bodies.count, 1)
        reply(h)
        _ = await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.chatID), [42, 42])
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
        XCTAssertTrue(h.allow.ids.isEmpty)
    }

    func testGC05RejectsUnresolvedNonGroupCaseAndInitialFailureWithPositiveControl() async throws {
        for mode in 0..<4 {
            let (h, _, e) = try setup(groups: mode == 1 ? ["direct"] : (mode == 2 ? [group.uppercased()] : nil))
            switch mode {
            case 0: await e.showChats([])
            case 1: await e.showChats(chats(guid: "direct", isGroup: false))
            case 2: await e.showChats(chats())
            default: _ = await e.applyChatList(.failed)
            }
            let result = await receive(e, input(guid: mode == 1 ? "direct" : nil))
            XCTAssertEqual(result, .ignoredNotAllowed)
            XCTAssertTrue(h.webhook.bodies.isEmpty)
        }
        let (h, _, e) = try setup()
        await e.showChats(chats())
        let result = await receive(e, input())
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.webhook.bodies.count, 1)
    }

    func testGC06WatchGuidMismatchRejectsAndMatchingGuidDelivers() async throws {
        let (h, _, e) = try setup()
        await e.showChats(chats())
        let mismatch = await receive(e, input(guid: other))
        XCTAssertNotEqual(mismatch, .delivered)
        XCTAssertTrue(h.webhook.bodies.isEmpty)
        await e.showChats(chats())
        await e.showChats(chats())
        let match = await receive(e, input(2))
        XCTAssertEqual(match, .delivered)
        XCTAssertEqual(h.webhook.bodies.count, 1)
    }

    func testGC06ReceiveBindingChecksSuppliedGUID() {
        var auth = ConfigGroupAuthorization()
        auth.observe(chats(), guids: [group])
        XCTAssertTrue(auth.permitsReceive(42, guid: group))
        XCTAssertTrue(auth.permitsReceive(42, guid: nil))
        XCTAssertFalse(auth.permitsReceive(42, guid: other))
    }

    func testGC10EveryPermissionSourceMustMatchBeforeSending() async throws {
        let (h, p, e) = try setup()
        await e.showChats(chats())
        let delivered = await receive(e, input())
        XCTAssertEqual(delivered, .delivered)
        p.config.groupChatGUIDs = []
        await e.setChatEnabled(42, guid: other, enabled: true)
        p.config.groupChatGUIDs = [group]
        reply(h)
        _ = await e.pollReplies()
        XCTAssertTrue(h.sender.sent.isEmpty)
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("reply"))
        XCTAssertTrue(h.log.records.contains { $0.code == "reply_chat_guid_mismatch" })
    }

    func testGC07MenuOffDoesNotRevokeConfig() async throws {
        let (h, _, e) = try setup(menu: true)
        await e.showChats(chats())
        await e.setChatEnabled(42, enabled: false)
        let result = await receive(e, input())
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(h.allow.ids, [42])
        XCTAssertTrue(h.log.records.contains { $0.code == "allowlist_off_config_locked" })
    }

    func testGC08ConfigRemovalRevokesUnlessMenuStillAllows() async throws {
        for menu in [false, true] {
            let (h, p, e) = try setup(menu: menu)
            await e.showChats(chats())
            let first = await receive(e, input())
            XCTAssertEqual(first, .delivered)
            p.config = try JSONDecoder().decode(GenieConfig.self, from: Data("{\"webhook_url\":\"https://127.0.0.1/webhook\",\"reply_fetch_url\":\"https://127.0.0.1/replies\"}".utf8))
            let second = await receive(e, input(2))
            XCTAssertEqual(second, menu ? .delivered : .ignoredNotAllowed)
            if menu { XCTAssertNil(try payload(h, at: 1)["sender_handle"]) }
            reply(h)
            _ = await e.pollReplies()
            XCTAssertEqual(h.sender.sent.count, menu ? 2 : 0)
            if !menu { XCTAssertTrue(h.log.records.contains { $0.code == "reply_chat_disabled" }) }
        }
    }

    func testGC09DatabaseSwapRequiresNewListThenBindsNewRowID() async throws {
        let (h, _, e) = try setup()
        await e.showChats(chats())
        let first = await receive(e, input())
        XCTAssertEqual(first, .delivered)
        _ = await receive(e, input(2, guid: other))
        let oldBinding = await e.ingestWatchLine(watchLine(id: 3, guid: "old-binding", chat: 42, fromMe: false, text: "🪔 old", isGroup: true))
        XCTAssertEqual(oldBinding, .ignoredNotAllowed)
        let beforeList = await receive(e, input(3, chat: 84))
        XCTAssertEqual(beforeList, .ignoredNotAllowed)
        await e.showChats(chats(84))
        let afterList = await receive(e, input(4, chat: 84))
        XCTAssertEqual(afterList, .delivered)
        XCTAssertEqual(try payload(h, at: 1)["chat_id"] as? Int, 84)
    }

    func testGC10ConfigRemovalBetweenPartsStopsBody() async throws {
        let (h, p, e) = try setup()
        await e.showChats(chats())
        let result = await receive(e, input())
        XCTAssertEqual(result, .delivered)
        reply(h)
        h.sender.onSend = { p.config = GenieConfig.productDefaults }
        _ = await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 1)
        XCTAssertTrue(h.log.records.contains { $0.code == "reply_chat_disabled" })
    }

    func testGC10EmptyMissingFailedListHoldsThenRecovers() async throws {
        for mode in 0..<3 {
            let (h, _, e) = try setup()
            await e.showChats(chats())
            let result = await receive(e, input())
            XCTAssertEqual(result, .delivered)
            reply(h)
            if mode == 0 { await e.showChats([]) }
            if mode == 1 { await e.showChats(chats(99, guid: other)) }
            if mode == 2 { _ = await e.applyChatList(.failed) }
            _ = await e.pollReplies()
            XCTAssertTrue(h.sender.sent.isEmpty)
            await e.showChats(chats())
            reply(h)
            _ = await e.pollReplies()
            XCTAssertEqual(h.sender.sent.count, 2)
        }
    }

    func testGC10RemovalWhileCheckingLockStopsFirstPart() async throws {
        let (h, p, e) = try setup()
        await e.showChats(chats())
        let result = await receive(e, input())
        XCTAssertEqual(result, .delivered)
        reply(h)
        h.lock.onState = { p.config.groupChatGUIDs = [] }
        _ = await e.pollReplies()
        XCTAssertTrue(h.sender.sent.isEmpty)
        XCTAssertTrue(h.log.records.contains { $0.code == "reply_chat_disabled" })
    }

    func testGC10DirectoryDisappearsBetweenPartsAndBodyResumesAfterRecovery() async throws {
        let (h, _, e) = try setup()
        await e.showChats(chats())
        let result = await receive(e, input())
        XCTAssertEqual(result, .delivered)
        reply(h)
        h.sender.onSend = { await e.showChats([]) }
        _ = await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText])
        XCTAssertFalse(h.state.state.handledReplyIDs.contains("reply"))
        h.sender.onSend = nil
        await e.showChats(chats())
        reply(h)
        _ = await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
    }

    func testGC12MissingCreatedAtOmitsOnlyThatOptionalKey() async throws {
        let (h, _, e) = try setup()
        await e.showChats(chats())
        var event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input().utf8)) as? [String: Any])
        event.removeValue(forKey: "created_at")
        let data = try JSONSerialization.data(withJSONObject: event)
        let result = await e.ingestWatchLine(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(result, .delivered)
        let body = try payload(h)
        XCTAssertEqual(Set(body.keys), ["v", "event", "idempotency_key", "guid", "chat_id", "text", "sender_is_me", "sender_name", "sender_handle"])
    }

    func testGC12NormalizedHandleAndUnknownHandleUseTenKeys() async throws {
        for (raw, expected) in [(" +1 555 010 0000 ", "tel:+15550100000"), ("FAMILY@EXAMPLE.COM", "email:family@example.com"), ("", "")] {
            let (h, _, e) = try setup()
            await e.showChats(chats())
            let result = await receive(e, input(sender: raw))
            XCTAssertEqual(result, .delivered)
            let body = try payload(h)
            XCTAssertEqual(body.count, 10)
            XCTAssertEqual(body["sender_handle"] as? String, expected)
            XCTAssertEqual(body["v"] as? Int, 1)
        }
    }

    func testGC13JobExcludesHandleAndEmptyURLFallbackIncludesIt() async throws {
        for jobURL in ["http://127.0.0.1/job", ""] {
            let (h, p, e) = try setup()
            p.config.jobChatIDs = [42]
            p.config.jobWebhookURL = jobURL
            h.secrets = StaticSecret(webhook: "hook-secret", reply: nil, job: "job-secret")
            await e.showChats(chats())
            let result = await receive(e, input())
            if !jobURL.isEmpty {
                XCTAssertEqual(result, .delivered)
                XCTAssertEqual(try payload(h).count, 9)
                XCTAssertNil(try payload(h)["sender_handle"])
            } else {
                XCTAssertEqual(result, .delivered)
                XCTAssertEqual(try payload(h).count, 10)
            }
        }
    }

    func testGC25GroupNoticesAreCountOnlyGatedAndRearmed() async throws {
        let (h, p, e) = try setup()
        await e.showChats([])
        await e.showChats([])
        var snapshot = await e.snapshot()
        XCTAssertEqual(snapshot.configGroupUnresolved, 1)
        XCTAssertEqual(h.log.records.filter { $0.code == "group_chat_not_found" }.count, 1)
        XCTAssertEqual(h.log.records.first { $0.code == "group_chat_not_found" }?.detail, "1")
        await e.showChats(chats())
        snapshot = await e.snapshot()
        XCTAssertEqual(snapshot.configGroupUnresolved, 0)
        XCTAssertEqual(snapshot.configChatIDs, [42])
        await e.showChats([])
        XCTAssertEqual(h.log.records.filter { $0.code == "group_chat_not_found" }.count, 2)
        p.config.groupChatGUIDs = ["direct"]
        _ = await e.ingestWatchLine("")
        await e.showChats(chats(99, guid: "direct", isGroup: false))
        snapshot = await e.snapshot()
        XCTAssertEqual(snapshot.configGroupUnresolved, 1)
        XCTAssertTrue(h.log.records.contains { $0.code == "group_chat_not_group" && $0.detail == "1" })
        let logs = String(describing: h.log.records)
        XCTAssertFalse(logs.contains(group))
        XCTAssertNil(snapshot.lastError)
        XCTAssertNil(snapshot.holdNotice)
    }

    func testGC01UnreadableReloadKeepsPreviousGroupPermission() async throws {
        let h = Harness()
        let data = try JSONSerialization.data(withJSONObject: ["group_chat_guids": [group], "webhook_url": "https://127.0.0.1/webhook"])
        let provider = GroupJSONConfig(data)
        let cfg = try provider.load()
        let e = try GenieEngine(configProvider: provider, initialConfig: cfg, stateStore: h.state,
            allowlistStore: h.allow, replySource: h.replies, sender: h.sender, webhook: h.webhook,
            secrets: h.secrets, lock: h.lock, clock: h.clock, log: h.log)
        await e.showChats(chats())
        let first = await receive(e, input())
        XCTAssertEqual(first, .delivered)
        for json in ["{\"group_chat_guids\":[1]}", "{\"reply_marker\":1}"] {
            provider.data = Data(json.utf8)
            _ = await e.ingestWatchLine("")
            let snapshot = await e.snapshot()
            XCTAssertEqual(snapshot.lastError, "config_unreadable")
            let result = await receive(e, input(h.webhook.bodies.count + 1))
            XCTAssertEqual(result, .delivered)
        }
        XCTAssertEqual(h.webhook.bodies.count, 3)
    }

    func testRetryRefreshRevokesPermissionOrHandleSharing() async throws {
        for menu in [false, true] {
            let (h, p, e) = try setup(menu: menu)
            await e.showChats(chats())
            h.webhook.results = [.success(WebhookHTTPResult(statusCode: 503)), .success(WebhookHTTPResult(statusCode: 200))]
            h.clock.onSleep = { p.config = try! JSONDecoder().decode(GenieConfig.self, from: Data("{\"webhook_url\":\"https://127.0.0.1/webhook\"}".utf8)) }
            let result = await receive(e, input())
            XCTAssertEqual(result, menu ? .delivered : .ignoredNotAllowed)
            XCTAssertEqual(h.webhook.bodies.count, menu ? 2 : 1)
            XCTAssertNotNil(try payload(h)["sender_handle"])
            if menu { XCTAssertNil(try payload(h, at: 1)["sender_handle"]) }
        }
    }
}

private final class GroupJSONConfig: ConfigProviding, @unchecked Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
    func load() throws -> GenieConfig { try JSONDecoder().decode(GenieConfig.self, from: data) }
}
