import Foundation
import XCTest
@testable import GenieCore

final class DoveReplyTests: XCTestCase {
    func testDV10DoveReplyIsTextBirdThenBody() async throws {
        let f = try DoveFixture()
        f.settings["reply_marker"] = "🕊️"
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        _ = await f.ingest(e, "🐦 x")
        f.reply()
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("answer")])
        XCTAssertEqual(f.h.sender.outgoing.map(\.chatID), [7, 7])
        XCTAssertEqual(f.h.sender.sent.first?.text.unicodeScalars.map(\.value), [0x1F426])
        XCTAssertEqual(ImsgCommand.sendArguments(chatID: 7, text: "🐦"), ["send", "--chat-id", "7", "--text", "🐦", "--json"])
    }

    func testDV11LampReplyInDoveChatKeepsGIF() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        _ = await f.ingest(e, "🪔 x")
        f.reply()
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("answer")])
    }

    func testDV12DoveReplyNeverLeavesItsChat() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        _ = await f.ingest(e, "🐦 x")
        for id in 2...4 { _ = await f.ingest(e, "🐦 request \(id)", id: id) }
        let rows: [[String: Any]] = [42, nil, 7, 7.5].enumerated().map { index, chat in
            var props: [String: Any] = [
                "reply_id": ["title": [["plain_text": "reply-\(index + 1)"]]],
                "in_reply_to_guid": ["rich_text": [["plain_text": "incoming-\(index + 1)"]]],
                "text": ["rich_text": [["plain_text": "answer"]]],
            ]
            if let chat { props["chat_id"] = ["number": chat] }
            return ["properties": props, "created_time": ISO8601.string(from: f.h.clock.now())]
        }
        let json = try JSONSerialization.data(withJSONObject: ["results": rows])
        let decoded = try NotionPageDecoder.decode(json)
        XCTAssertNil(decoded.rows.last?.reply)
        f.h.replies.pages = [.init(replies: decoded.rows.compactMap(\.reply), nextCursor: nil)]
        f.advance()
        _ = await p.tick()
        XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_chat_mismatch" })
        XCTAssertEqual(f.h.sender.outgoing.map(\.chatID), [7, 7, 7, 7])
    }

    func testDV13DoveReplyHoldsForMissingListAndResumes() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        let p = f.poller(e, reads: [
            .parsed(.init(chats: f.chats, failedLineCount: 0)),
            .parsed(.init(chats: Array(f.chats.dropFirst()), failedLineCount: 0)),
            .failed,
            .parsed(.init(chats: f.chats, failedLineCount: 0)),
        ])
        _ = await p.tick()
        _ = await f.ingest(e, "🐦 x")
        f.reply()
        for _ in 1...2 {
            await p.requestChatsRefresh()
            f.advance()
            _ = await p.tick()
            XCTAssertTrue(f.h.sender.outgoing.isEmpty)
            XCTAssertFalse(f.h.log.records.contains { $0.code == "reply_dove_chat_disabled" })
        }
        await p.requestChatsRefresh()
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("answer")])
    }

    func testDV13NonGroupDoveReplyIsTerminal() async throws {
        let f = try DoveFixture()
        let guid = "sample-family-chat"
        f.chats[0].guid = guid
        f.settings["group_chat_guids"] = [guid, DoveFixture.other]
        f.settings["dove_chat_guids"] = [guid]
        let e = try f.engine()
        let nonGroup = ChatSummary(id: 7, title: "family", isGroup: false, guid: guid)
        let p = f.poller(e, reads: [
            .parsed(.init(chats: f.chats, failedLineCount: 0)),
            .parsed(.init(chats: [nonGroup] + f.chats.dropFirst(), failedLineCount: 0)),
            .parsed(.init(chats: f.chats, failedLineCount: 0)),
        ])
        _ = await p.tick()
        let accepted = await f.ingest(e, "🐦 request")
        XCTAssertEqual(accepted, .delivered)
        f.reply("old answer")

        await p.requestChatsRefresh()
        f.advance()
        _ = await p.tick()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "group_chat_not_group" })
        XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_dove_chat_disabled" })

        f.reply("old answer")
        await p.requestChatsRefresh()
        f.advance()
        _ = await p.tick()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty)

        let newRequest = await f.ingest(e, "🐦 new request", id: 2)
        XCTAssertEqual(newRequest, .delivered)
        f.reply("new answer", id: 2)
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("new answer")])
    }

    func testDV13DoveRevocationStopsBeforeMarkerOrBody() async throws {
        for revokeAfterMarker in [false, true] {
            let f = try DoveFixture()
            let e = try f.engine()
            let p = f.poller(e)
            _ = await p.tick()
            _ = await f.ingest(e, "🐦 x")
            let disabled = try JSONSerialization.data(withJSONObject: f.settings.merging(["dove_chat_guids": []]) { _, new in new })
            let file = f.paths.configFile
            if revokeAfterMarker { f.h.sender.onSend = { try? disabled.write(to: file, options: .atomic) } }
            else { try disabled.write(to: file, options: .atomic) }
            f.reply()
            f.advance()
            _ = await p.tick()
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), revokeAfterMarker ? [.text("🐦")] : [])
            XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_dove_chat_disabled" })
        }
    }

    func testDV13LockReturnRevocationAndDatabaseSwap() async throws {
        for swap in [false, true] {
            let f = try DoveFixture()
            let e = try f.engine()
            let p = f.poller(e)
            _ = await p.tick()
            _ = await f.ingest(e, "🐦 x")
            f.reply()
            let disabled = try JSONSerialization.data(withJSONObject: f.settings.merging(["dove_chat_guids": []]) { _, new in new })
            let file = f.paths.configFile
            let differentChat = ChatSummary(id: 7, title: "new room", isGroup: true, guid: "iMessage;+;chat000000000000000004")
            let calls = EventLog()
            f.h.lock.onState = {
                calls.append("lock")
                guard calls.snapshot().count == 2 else { return }
                if swap { _ = await e.applyChatList(.parsed(.init(chats: [differentChat], failedLineCount: 0))) }
                else { try? disabled.write(to: file, options: .atomic) }
            }
            f.advance()
            _ = await p.tick()
            XCTAssertTrue(f.h.sender.outgoing.isEmpty)
            let expected = swap ? "messages_db_reset" : "reply_dove_chat_disabled"
            XCTAssertTrue(f.h.log.records.contains { $0.code == expected })
            if swap { XCTAssertTrue(f.h.state.state.routes.isEmpty) }
        }
    }

    func testDV13PersistedDoveRouteRejectsReusedChatIDWithoutKnownChat() async throws {
        let f = try DoveFixture()
        let store = FileStateStore(paths: f.paths)
        f.h.store = store
        f.settings["dove_chat_guids"] = [DoveFixture.group, DoveFixture.other]
        let a = try f.engine()
        _ = await f.poller(a).tick()
        let accepted = await f.ingest(a, "🐦 x")
        XCTAssertEqual(accepted, .delivered)

        // 上限で過去の一覧識別子が押し出された状態を再現する。
        var state = try store.load()
        state.knownChats.removeAll { $0.id == 7 }
        try store.save(state)
        f.chats.removeAll { $0.id == 7 || $0.id == 8 }
        f.chats.append(.init(id: 7, title: "other room", isGroup: true, guid: DoveFixture.other))
        let b = try f.engine()
        f.reply()
        _ = await f.poller(b).tick()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_chat_guid_mismatch" })
    }

    func testDV14OwnMarkerEchoStopsAtSentGUID() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        _ = await f.ingest(e, "🐦 x")
        f.reply()
        f.advance()
        _ = await p.tick()
        let count = f.h.webhook.bodies.count
        let marker = await f.ingest(e, "🐦", id: 2, guid: "sent-1")
        let body = await f.ingest(e, "answer", id: 3, guid: "sent-2")
        let fingerprint = await f.ingest(e, "🐦", id: 4)
        XCTAssertEqual(marker, .ignoredSentGUID)
        XCTAssertEqual(body, .ignoredSentGUID)
        XCTAssertEqual(fingerprint, .ignoredFingerprint)
        XCTAssertEqual(f.h.webhook.bodies.count, count)
        XCTAssertEqual(count, 1)
    }

    func testDV16DoveBodyAndAddressee() async throws {
        let f = try DoveFixture()
        f.settings["sender_names"] = ["family@example.com": "🐦 家族"]
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        for (i, text) in ["🐦 🧞‍♂️ 答え", "🐦", "🐦 🪔 x", "🐦‍🔥 x"].enumerated() {
            let id = i + 1
            _ = await f.ingest(e, "🐦 x", id: id, fromMe: false)
            f.reply(text, id: id)
            f.advance()
            _ = await p.tick()
        }
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("答え"), .text("🐦"), .text("🐦‍🔥 x")])
        XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_empty_body" })
        XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_still_matches_signal" })
    }

    func testDV17LampBodyStartingWithDoveIsDroppedInDoveChat() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        _ = await f.ingest(e, "🪔 x")
        f.reply("🧞‍♂️ 🐦 x")
        f.advance()
        _ = await p.tick()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_still_matches_dove" })
        _ = await f.ingest(e, "🪔 x", id: 2, chat: 42)
        f.reply("🐦 x", chat: 42, id: 2)
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("🐦 x")])
    }

    func testDV17LampBodyRechecksAfterHoldAndMarker() async throws {
        for enableAfterMarker in [false, true] {
            let f = try DoveFixture()
            f.settings["dove_chat_guids"] = []
            let e = try f.engine()
            let p = f.poller(e)
            _ = await p.tick()
            _ = await f.ingest(e, "🪔 x")
            f.settings["dove_chat_guids"] = [DoveFixture.group]
            let enabled = try JSONSerialization.data(withJSONObject: f.settings)
            let file = f.paths.configFile
            if enableAfterMarker { f.h.sender.onSend = { try? enabled.write(to: file, options: .atomic) } }
            else { f.h.lock.locked = true }
            f.reply("🐦 x")
            f.advance()
            _ = await p.tick()
            if !enableAfterMarker {
                try f.write()
                f.h.lock.locked = false
                f.advance()
                _ = await p.tick()
            }
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), enableAfterMarker ? [.file(expectedGIFPath())] : [])
            XCTAssertTrue(f.h.log.records.contains { $0.code == "reply_still_matches_dove" })
        }
    }

    func testDV17LampRechecksPermissionAfterSavingSendIntent() async throws {
        for revokedPart in [SendPart.marker, .body, nil] {
            let f = try DoveFixture()
            f.settings["dove_chat_guids"] = []
            let disabled = try JSONSerialization.data(withJSONObject: f.settings.merging(
                ["group_chat_guids": [DoveFixture.other]]) { _, new in new })
            let file = f.paths.configFile
            let store = RecordingStateStore { state in
                guard let revokedPart, state.pendingSends.contains(where: { $0.part == revokedPart }) else { return }
                try disabled.write(to: file, options: .atomic)
            }
            f.h.store = store
            let e = try f.engine()
            let p = f.poller(e)
            _ = await p.tick()
            let result = await f.ingest(e, "🪔 x")
            XCTAssertEqual(result, .delivered)
            f.reply("🐦 answer")
            f.advance()
            _ = await p.tick()

            let expected: [FakeOutgoing]
            switch revokedPart {
            case .marker: expected = []
            case .body: expected = [.file(expectedGIFPath())]
            case nil: expected = [.file(expectedGIFPath()), .text("🐦 answer")]
            }
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), expected, "\(String(describing: revokedPart))")
            XCTAssertEqual(f.h.log.records.filter { $0.code == "reply_chat_disabled" }.compactMap(\.detail),
                           revokedPart.map { [$0.rawValue] } ?? [])
            XCTAssertTrue(try store.load().pendingSends.isEmpty)
        }
    }

    func testDV18DoveTriggerSurvivesRestart() async throws {
        let f = try DoveFixture()
        f.h.store = FileStateStore(paths: f.paths)
        let a = try f.engine()
        _ = await f.poller(a).tick()
        _ = await f.ingest(a, "🐦 x")
        let b = try f.engine()
        f.reply()
        _ = await f.poller(b).tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("answer")])
    }

    func testDV18DoveResumesBodyAndLegacyRouteUsesGIF() async throws {
        let f = try DoveFixture()
        f.h.store = FileStateStore(paths: f.paths)
        let a = try f.engine()
        let p = f.poller(a)
        _ = await p.tick()
        _ = await f.ingest(a, "🐦 x")
        _ = await f.ingest(a, "🪔 x", id: 2)
        f.h.sender.onSend = { await a.setPaused(true) }
        f.reply()
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦")])
        f.h.sender.onSend = nil
        let b = try f.engine()
        await b.setPaused(false)
        let q = f.poller(b)
        f.reply()
        _ = await q.tick()
        f.reply("legacy body", id: 2)
        f.advance()
        _ = await q.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item),
                       [.text("🐦"), .text("answer"), .file(expectedGIFPath()), .text("legacy body")])
    }

    func testDV18InterruptedMarkerAndBodyRecoverFromJSON() async throws {
        let f = try DoveFixture()
        f.h.store = FileStateStore(paths: f.paths)
        let a = try f.engine()
        let p = f.poller(a)
        _ = await p.tick()
        _ = await f.ingest(a, "🐦 x")
        let markerSnapshot = f.paths.root.appendingPathComponent("marker-pending.json")
        let bodySnapshot = f.paths.root.appendingPathComponent("body-pending.json")
        let liveState = f.paths.stateFile
        let calls = EventLog()
        f.h.sender.onSend = {
            calls.append("send")
            let destination = calls.snapshot().count == 1 ? markerSnapshot : bodySnapshot
            try? FileManager.default.copyItem(at: liveState, to: destination)
        }
        f.reply()
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("answer")])
        f.h.sender.onSend = nil

        let markerState = try Data(contentsOf: markerSnapshot)
        try markerState.write(to: liveState)
        let b = try f.engine()
        f.reply()
        _ = await f.poller(b).tick()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "send_interrupted" })

        let bodyState = try Data(contentsOf: bodySnapshot)
        try bodyState.write(to: liveState)
        let c = try f.engine()
        f.h.sender.script = [.failure(.uncertain)]
        f.reply()
        _ = await f.poller(c).tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("answer"), .text("answer")])
        let letters = try String(contentsOf: f.paths.deadLetterFile, encoding: .utf8)
        XCTAssertTrue(letters.contains("body_send_uncertain"))
    }

    func testDV20OutboundRawAndFinalBirdBodiesTerminate() async throws {
        let f = try DoveFixture()
        f.settings["outbound_notion_data_source_id"] = "11111111-1111-4111-8111-111111111111"
        f.settings["outbound_targets"] = ["family": DoveFixture.group]
        let e = try f.engine()
        let p = f.poller(e)
        for (i, text) in ["🐦 お知らせ", "🧞‍♂️ 🐦 お知らせ", "通常の通知"].enumerated() {
            f.outbound.entries.append(.init(pageID: "page-\(i)", idempotencyKey: "key-\(i)",
                target: .family, text: text, createdAt: ISO8601.string(from: f.h.clock.now()), invalidCode: nil))
        }
        _ = await p.tick()
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("通常の通知")])
        XCTAssertEqual(f.h.state.deadLetters.map(\.error), ["outbound_dove_body", "outbound_dove_body"])
        XCTAssertEqual(f.h.state.deadLetters.map(\.kind), ["outbound", "outbound"])
    }

    func testDV20OutboundRechecksAfterHoldAndMarker() async throws {
        for enableAfterMarker in [false, true] {
            let f = try DoveFixture()
            f.settings["dove_chat_guids"] = []
            f.settings["outbound_notion_data_source_id"] = "11111111-1111-4111-8111-111111111111"
            f.settings["outbound_targets"] = ["family": DoveFixture.group]
            let e = try f.engine()
            let p = f.poller(e)
            f.outbound.entries = [.init(pageID: "page-0000", idempotencyKey: "key-0000",
                target: .family, text: "🐦 お知らせ", createdAt: ISO8601.string(from: f.h.clock.now()), invalidCode: nil)]
            f.settings["dove_chat_guids"] = [DoveFixture.group]
            let enabled = try JSONSerialization.data(withJSONObject: f.settings)
            let file = f.paths.configFile
            if enableAfterMarker { f.h.sender.onSend = { try? enabled.write(to: file, options: .atomic) } }
            else { f.h.lock.locked = true }
            _ = await p.tick()
            if !enableAfterMarker {
                try f.write()
                f.h.lock.locked = false
            }
            f.advance()
            _ = await p.tick()
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), enableAfterMarker ? [.file(expectedGIFPath())] : [])
            XCTAssertEqual(f.h.state.deadLetters.map(\.error), ["outbound_dove_body"])
        }
    }

    func testDV22DoveValuesStayOutOfPersistentOutputs() async throws {
        let f = try DoveFixture()
        let webhookSecret = "sample-dv22-webhook-secret"
        f.h.secrets = StaticSecret(webhook: webhookSecret, reply: nil)
        f.h.store = FileStateStore(paths: f.paths)
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        _ = await f.ingest(e, "🐦 private input", fromMe: false)
        f.h.webhook.results = [.success(.init(statusCode: 400))]
        _ = await f.ingest(e, "🐦 private failure", id: 2, fromMe: false)
        _ = await f.ingest(e, "🪔 ordinary lamp", id: 3)
        f.h.sender.script = [.failure(.failed)]
        f.reply("private answer")
        f.advance()
        _ = await p.tick()
        _ = await f.ingest(e, "🐦 another private input", id: 4)
        let markerGUID = "sample-dove-marker-receipt"
        let bodyGUID = "sample-dove-body-receipt"
        f.h.sender.script = [
            .success(.init(id: 20, guid: markerGUID, status: "sent")),
            .success(.init(id: 21, guid: bodyGUID, status: "sent")),
        ]
        f.reply("private success", id: 4)
        f.advance()
        _ = await p.tick()
        let successLogs = f.h.log.records.filter { $0.code == "reply_sent" }
        XCTAssertEqual(successLogs.map(\.detail), ["dove", "body"])
        XCTAssertTrue(successLogs.allSatisfy { $0.guid == nil })
        XCTAssertFalse(f.h.webhook.secrets.isEmpty)
        XCTAssertTrue(f.h.webhook.secrets.allSatisfy { $0 == webhookSecret })

        let state = try Data(contentsOf: f.paths.stateFile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: state) as? [String: Any])
        let routes = json["routes"] as? [[String: Any]]
        XCTAssertEqual(routes?.compactMap { $0["trigger"] as? String }, ["dove", "dove", "dove"])
        let lamp = routes?.first { $0["guid"] as? String == "incoming-3" }
        XCTAssertNotNil(lamp)
        XCTAssertNil(lamp?["trigger"])
        XCTAssertNil(lamp?["chat_guid_hash"])
        let groupHash = SHA256.hex(Data(DoveFixture.group.utf8))
        XCTAssertEqual(routes?.compactMap { $0["chat_guid_hash"] as? String }, Array(repeating: groupHash, count: 3))
        let logs = String(decoding: try JSONEncoder().encode(f.h.log.records), as: UTF8.self)
        let letters = try String(contentsOf: f.paths.deadLetterFile, encoding: .utf8)
        for output in [String(decoding: state, as: UTF8.self), logs, letters, String(describing: await e.snapshot())] {
            for privateValue in ["private input", "private failure", "another private input",
                                 "private answer", "private success", "ordinary lamp",
                                 "family@example.com", "request_text", "dove_chat_guids", webhookSecret] {
                XCTAssertFalse(output.contains(privateValue))
            }
        }

        // 生のトーク GUID を許すのは state の known_chats[].guid だけ。
        let knownChats = try XCTUnwrap(json["known_chats"] as? [[String: Any]])
        XCTAssertTrue(knownChats.contains { $0["guid"] as? String == DoveFixture.group })
        json["known_chats"] = knownChats.map { $0.filter { $0.key != "guid" } }
        let remainingState = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        for output in [remainingState, logs, letters] {
            for chat in f.chats {
                XCTAssertFalse(output.contains(chat.guid))
            }
        }

        // webhook の guid は受信したメッセージの GUID。送信結果の GUID はログと deadletter に出さない。
        XCTAssertTrue(f.h.log.records.contains { $0.code == "webhook_delivered" && $0.guid == "incoming-1" })
        let entries = try letters.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(DeadLetterEntry.self, from: Data($0.utf8))
        }
        XCTAssertTrue(entries.contains { $0.kind == "webhook" && $0.error == "webhook_http_400" && $0.guid == "incoming-2" })
        XCTAssertTrue(entries.contains { $0.error == "send_failed" })
        for output in [logs, letters] {
            XCTAssertFalse(output.contains(markerGUID))
            XCTAssertFalse(output.contains(bodyGUID))
        }
    }

    func testDV23LampAndDoveShareRateWindow() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        var replies: [FetchedReply] = []
        for id in 1...6 {
            let signal = id.isMultiple(of: 2) ? "🐦" : "🪔"
            _ = await f.ingest(e, signal + " request", id: id)
            replies.append(.init(id: "reply-\(id)", chatID: 7, text: "answer-\(id)",
                inReplyToGUID: "incoming-\(id)", createdAt: ISO8601.string(from: f.h.clock.now())))
        }
        f.h.replies.pages = [.init(replies: replies, nextCursor: nil)]
        f.advance()
        _ = await p.tick()
        XCTAssertEqual(f.h.sender.outgoing.count, 10)
        XCTAssertEqual(f.h.state.state.haltedChatIDs, [7])
        let held = await e.snapshot().heldCount
        XCTAssertEqual(held, 1)
        f.h.clock.current = f.h.clock.now().addingTimeInterval(61)
        await e.resumeRateLimit(chatID: 7)
        XCTAssertEqual(Array(f.h.sender.outgoing.map(\.item).suffix(2)), [.text("🐦"), .text("answer-6")])
        XCTAssertEqual(f.h.sender.outgoing.count, 12)
    }

    func testDV23DoveBodyResendsOnce() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        let p = f.poller(e)
        _ = await p.tick()
        _ = await f.ingest(e, "🐦 x")
        f.h.sender.script = [.success(.init(id: 1, guid: "marker-0000", status: "sent")), .failure(.uncertain), .failure(.uncertain)]
        f.reply()
        for _ in 1...3 { f.advance(); _ = await p.tick() }
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("🐦"), .text("answer"), .text("answer")])
        XCTAssertEqual(f.h.state.deadLetters.count, 1)
    }
}
