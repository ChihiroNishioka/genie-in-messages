import XCTest
@testable import GenieCore

final class SenderHandleTests: XCTestCase {
    func testJapanesePhoneNotationCollapses() {
        let expected = SenderHandle.normalize("090-0000-0000")
        XCTAssertEqual(expected, "tel:09000000000")
        for raw in [
            "090-0000-0000",
            "090 0000 0000",
            "(090) 0000-0000",
            "090.0000.0000",
            "+81 90 0000 0000",
            "+81-90-0000-0000",
            "+819000000000",
            "+81 090 0000 0000",
            "0081 90 0000 0000",
            "819000000000",
            "8109000000000",
            "＋８１ ９０ ００００ ００００",
        ] {
            XCTAssertEqual(SenderHandle.normalize(raw), expected, raw)
        }
    }

    func testEmailCaseAndDistinctPhones() {
        XCTAssertEqual(
            SenderHandle.normalize("  Hana@Example.com "),
            SenderHandle.normalize("hana@example.com")
        )
        XCTAssertNotEqual(
            SenderHandle.normalize("hana+home@example.com"),
            SenderHandle.normalize("hana@example.com")
        )
        XCTAssertNotEqual(
            SenderHandle.normalize("hana @example.com"),
            SenderHandle.normalize("hana@example.com")
        )
        XCTAssertNotEqual(
            SenderHandle.normalize("09000000000"),
            SenderHandle.normalize("09000000001")
        )
        XCTAssertNil(SenderHandle.normalize("not-a-number"))
        XCTAssertNil(SenderHandle.normalize("   "))
        // + の無い短い 81 は国番号にしない。+81 とは揃えない。
        XCTAssertNotEqual(SenderHandle.normalize("811234"), SenderHandle.normalize("+81 1234"))
    }

    func testOtherCountryKeepsThePlus() {
        XCTAssertEqual(
            SenderHandle.normalize("+1 555 010 0000"),
            SenderHandle.normalize("+1-555-010-0000")
        )
        XCTAssertEqual(SenderHandle.normalize("+1 555 010 0000"), "tel:+15550100000")
        XCTAssertEqual(
            SenderHandle.normalize("001 555 010 0000"),
            SenderHandle.normalize("+1 555 010 0000")
        )
        XCTAssertNotEqual(
            SenderHandle.normalize("+1 555 010 0000"),
            SenderHandle.normalize("090-0000-0000")
        )
    }
}

final class AllowedSenderConfigTests: XCTestCase {
    func testOldConfigDecodesAndKeepsSelfOnly() throws {
        let old = Data(#"{"webhook_url":"https://127.0.0.1/hook","marker":"ok"}"#.utf8)
        let config = try JSONDecoder().decode(GenieConfig.self, from: old)
        XCTAssertEqual(config.webhookURL, "https://127.0.0.1/hook")
        XCTAssertEqual(config.marker, "ok")
        XCTAssertEqual(config.selfSenderName, "me")
        XCTAssertTrue(config.allowedSenders.isEmpty)

        let blank = Data(#"{"self_sender_name":"  ","allowed_senders":null}"#.utf8)
        let blanked = try JSONDecoder().decode(GenieConfig.self, from: blank)
        XCTAssertEqual(blanked.selfSenderName, "me")
        XCTAssertTrue(blanked.allowedSenders.isEmpty)

        let partial = Data(#"""
        {"allowed_senders":[{},{"chat_id":42,"senders":[
          {"handle":"+81 90 0000 0000","name":"hana"},
          {"handle":"090-0000-0000","name":"later"},
          {"handle":"not a phone","name":"skip"},
          {"name":"missing-handle"},
          {"handle":"Hana@Example.com"}
        ]}]}
        """#.utf8)
        let parsed = try JSONDecoder().decode(GenieConfig.self, from: partial)
        XCTAssertEqual(parsed.allowedSenders.count, 1)
        XCTAssertEqual(parsed.allowedSenders[0].chatID, 42)
        XCTAssertEqual(parsed.allowedSenders[0].senders.map(\.name), ["hana", ""])
        XCTAssertEqual(parsed.allowedSenders[0].senders[0].payloadName, "hana")
        XCTAssertEqual(parsed.allowedSenders[0].senders[1].payloadName, "sender")
        XCTAssertFalse(parsed.allowedSenders[0].senders.contains { $0.handle.contains("not") })
    }

    func testExampleFileShowsTheNewKeysWithoutPersonalValues() throws {
        let url = repoRoot().appendingPathComponent("config.example.json")
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("self_sender_name"))
        XCTAssertTrue(text.contains("allowed_senders"))
        XCTAssertFalse(text.contains("@"))
        let config = try JSONDecoder().decode(GenieConfig.self, from: data)
        XCTAssertEqual(config.selfSenderName, "me")
        XCTAssertTrue(config.allowedSenders.isEmpty)
    }
}

final class AllowedSenderEngineTests: XCTestCase {
    private let phone = "+81 90 0000 0000"
    private let phoneNational = "090-0000-0000"
    private let mail = "hana@example.com"
    private let mailMixed = "Hana@Example.com"
    private let stranger = "+81 70 0000 0002"

    private func familyConfig() -> GenieConfig {
        var config = GenieConfig.productDefaults
        config.webhookURL = "https://127.0.0.1/webhook"
        config.selfSenderName = "host"
        config.allowedSenders = [
            ChatSenders(chatID: 42, senders: [
                AllowedSender(handle: phoneNational, name: "hana"),
                AllowedSender(handle: mailMixed, name: "hana-mail"),
            ]),
        ]
        return config
    }

    private func groupLine(
        id: Int,
        guid: String,
        text: String,
        sender: String,
        fromMe: Bool = false,
        reaction: Bool = false,
        attachments: Bool = false
    ) -> String {
        watchLine(
            id: id,
            guid: guid,
            chat: 42,
            fromMe: fromMe,
            text: text,
            reaction: reaction,
            sender: sender,
            isGroup: true,
            participants: [phone, mail, stranger],
            attachments: attachments
        )
    }

    func testAllowedSenderLampReachesWebhookWithoutTheHandle() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        let engine = try harness.engine()
        let phoneResult = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "g-phone", text: "\u{1FA94} hi", sender: phone
        ))
        let mailResult = await engine.ingestWatchLine(groupLine(
            id: 2, guid: "g-mail", text: "\u{1FA94}\u{FE0F} mail", sender: mail
        ))
        XCTAssertEqual(phoneResult, .delivered)
        XCTAssertEqual(mailResult, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 2)

        let phoneBody = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(phoneBody.v, 1)
        XCTAssertEqual(phoneBody.senderIsMe, false)
        XCTAssertEqual(phoneBody.senderName, "hana")
        XCTAssertEqual(phoneBody.chatID, 42)
        XCTAssertEqual(phoneBody.keys, payloadKeys)
        assertNoHandle(String(data: harness.webhook.bodies[0], encoding: .utf8) ?? "")

        let mailBody = try payload(harness.webhook.bodies[1])
        XCTAssertEqual(mailBody.v, 1)
        XCTAssertEqual(mailBody.senderIsMe, false)
        XCTAssertEqual(mailBody.senderName, "hana-mail")
        XCTAssertEqual(mailBody.keys, payloadKeys)
        let mailJSON = String(data: harness.webhook.bodies[1], encoding: .utf8) ?? ""
        XCTAssertFalse(mailJSON.lowercased().contains("example.com"))
        XCTAssertFalse(mailJSON.contains("Hana@"))
        XCTAssertFalse(mailJSON.contains(mail))
    }

    func testDisallowedSenderLampIsInfoOnlyAndLogsNoBodyOrHandle() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        let engine = try harness.engine()
        let body = "QXBODY91"
        let result = await engine.ingestWatchLine(groupLine(
            id: 3, guid: "g-deny", text: "\u{1FA94} \(body)", sender: stranger
        ))
        XCTAssertEqual(result, .ignoredNotFromMe)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        let infos = harness.log.records.filter { $0.code == "ignored_sender" }
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].level, "info")
        XCTAssertNil(infos[0].detail)
        let rendered = renderedDiagnostics(harness)
        XCTAssertFalse(rendered.contains(body))
        XCTAssertFalse(rendered.contains(stranger))
        XCTAssertFalse(rendered.contains("07000000002"))
        XCTAssertFalse(rendered.contains("0000-0002"))
        XCTAssertFalse(rendered.contains("+81"))
        XCTAssertFalse(rendered.contains(phone))
        XCTAssertFalse(rendered.contains(mail))
    }

    func testSelfLampStillFiresWithConfiguredName() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        let engine = try harness.engine()
        let result = await engine.ingestWatchLine(groupLine(
            id: 4, guid: "g-me", text: "\u{1FA94} mine", sender: phone, fromMe: true
        ))
        XCTAssertEqual(result, .delivered)
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.v, 1)
        XCTAssertEqual(body.senderIsMe, true)
        XCTAssertEqual(body.senderName, "host")
        XCTAssertEqual(body.keys, payloadKeys)
        assertNoHandle(String(data: harness.webhook.bodies[0], encoding: .utf8) ?? "")
    }

    func testOldConfigStillReactsOnlyToSelf() async throws {
        let old = Data(#"{"webhook_url":"https://127.0.0.1/webhook"}"#.utf8)
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = try JSONDecoder().decode(GenieConfig.self, from: old)
        let engine = try harness.engine()
        let bodyToken = "QXOLD91"
        let strangerResult = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "g-old-deny", text: "\u{1FA94} \(bodyToken)", sender: phone
        ))
        let selfResult = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "g-old-me", chat: 42, fromMe: true, text: "\u{1FA94} mine"
        ))
        XCTAssertEqual(strangerResult, .ignoredNotFromMe)
        XCTAssertEqual(selfResult, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.senderIsMe, true)
        XCTAssertEqual(body.senderName, "me")
        XCTAssertEqual(body.v, 1)
        let rendered = renderedDiagnostics(harness)
        XCTAssertFalse(rendered.contains(phone))
        XCTAssertFalse(rendered.contains(bodyToken))
        XCTAssertFalse(rendered.contains("09000000000"))
    }

    func testLampInTheMiddleOrEndIsIgnoredForAllowedSenders() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        let engine = try harness.engine()
        let middle = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "g-mid", text: "see \u{1FA94} later", sender: phone
        ))
        let end = await engine.ingestWatchLine(groupLine(
            id: 2, guid: "g-end", text: "end \u{1FA94}", sender: phone
        ))
        let hidden = await engine.ingestWatchLine(groupLine(
            id: 3, guid: "g-hide", text: "\u{0601}\u{1FA94} no", sender: phone
        ))
        let variation = await engine.ingestWatchLine(groupLine(
            id: 4, guid: "g-vs", text: "\u{1FA94}\u{FE0F} ok", sender: phone
        ))
        let invisible = await engine.ingestWatchLine(groupLine(
            id: 5, guid: "g-zw", text: "\u{200B}\u{1FA94} ok", sender: phone
        ))
        XCTAssertEqual(middle, .ignoredNoSignal)
        XCTAssertEqual(end, .ignoredNoSignal)
        XCTAssertEqual(hidden, .ignoredNoSignal)
        XCTAssertEqual(variation, .delivered)
        XCTAssertEqual(invisible, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 2)
    }

    func testSameGroupMessageIsNotDeliveredTwice() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        harness.state.state.sentGUIDs = ["g-sent"]
        let engine = try harness.engine()
        let line = groupLine(id: 1, guid: "g-same", text: "\u{1FA94} once", sender: phone)
        let first = await engine.ingestWatchLine(line)
        let again = groupLine(id: 2, guid: "g-same", text: "\u{1FA94} once", sender: phone)
        let second = await engine.ingestWatchLine(again)
        XCTAssertEqual(first, .delivered)
        XCTAssertEqual(second, .duplicate)
        let sent = await engine.ingestWatchLine(groupLine(
            id: 3, guid: "g-sent", text: "\u{1FA94} echo", sender: phone
        ))
        XCTAssertEqual(sent, .ignoredSentGUID)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
    }

    func testOtherMemberGenieMarkerDoesNotTrigger() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        let engine = try harness.engine()
        let marker = GenieConfig.productDefaults.marker
        let result = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "g-marker", text: marker + " hello", sender: phone
        ))
        XCTAssertEqual(result, .ignoredNoSignal)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        XCTAssertFalse(harness.log.records.contains { $0.code == "ignored_sender" })
    }

    func testSelfChatFalseSideStaysIgnoredEvenIfHandleIsListed() async throws {
        let harness = Harness()
        harness.allow.ids = [7]
        var config = familyConfig()
        config.allowedSenders.append(
            ChatSenders(chatID: 7, senders: [AllowedSender(handle: phone, name: "hana")])
        )
        harness.config = config
        let engine = try harness.engine()
        let text = "\u{1FA94} echo"
        let echo = await engine.ingestWatchLine(watchLine(
            id: 10, guid: "in", chat: 7, fromMe: false, text: text, sender: phone
        ))
        let mine = await engine.ingestWatchLine(watchLine(
            id: 11, guid: "out", chat: 7, fromMe: true, text: text
        ))
        XCTAssertEqual(echo, .ignoredNotFromMe)
        XCTAssertEqual(mine, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.senderIsMe, true)
        XCTAssertFalse(harness.log.records.contains { $0.code == "ignored_sender" })
        assertNoHandle(renderedDiagnostics(harness))
    }

    func testReplyGoesToTheSameChat() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try harness.engine()
        let result = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "msg-1", text: "\u{1FA94} hi", sender: phone
        ))
        XCTAssertEqual(result, .delivered)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 42, text: "ok", guid: "msg-1")], nextCursor: nil),
        ]
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.map(\.chatID), [42])
    }

    func testReactionAndAttachmentOnlyAreIgnored() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = familyConfig()
        let engine = try harness.engine()
        let reaction = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "g-tap", text: "\u{1FA94}", sender: phone, reaction: true
        ))
        let attachment = await engine.ingestWatchLine(groupLine(
            id: 2, guid: "g-file", text: "", sender: phone, attachments: true
        ))
        let caption = await engine.ingestWatchLine(groupLine(
            id: 3, guid: "g-cap", text: "\u{1FA94} pic", sender: phone, attachments: true
        ))
        XCTAssertEqual(reaction, .ignoredReaction)
        XCTAssertEqual(attachment, .ignoredNoSignal)
        XCTAssertEqual(caption, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
    }

    func testUnlistedChatDoesNotLogOrDeliver() async throws {
        let harness = Harness()
        harness.config = familyConfig()
        let engine = try harness.engine()
        let allowedButChatOff = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "g-off", text: "\u{1FA94} hi", sender: phone
        ))
        XCTAssertEqual(allowedButChatOff, .ignoredNotAllowed)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        XCTAssertFalse(harness.log.records.contains { $0.code == "ignored_sender" })
    }

    func testDirectChatWithAParticipantCanMatch() async throws {
        let harness = Harness()
        harness.allow.ids = [9]
        var config = familyConfig()
        config.allowedSenders = [
            ChatSenders(chatID: 9, senders: [AllowedSender(handle: phoneNational, name: "hana")]),
        ]
        harness.config = config
        let engine = try harness.engine()
        let result = await engine.ingestWatchLine(watchLine(
            id: 1,
            guid: "g-dm",
            chat: 9,
            fromMe: false,
            text: "\u{1FA94} dm",
            sender: "+81-90-0000-0000",
            isGroup: false,
            participants: [phoneNational]
        ))
        XCTAssertEqual(result, .delivered)
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.senderIsMe, false)
        XCTAssertEqual(body.senderName, "hana")
        XCTAssertEqual(body.chatID, 9)
    }

    func testBlankDisplayNameDoesNotFallBackToTheHandle() async throws {
        let harness = Harness()
        harness.allow.ids = [42]
        var config = familyConfig()
        config.allowedSenders = [
            ChatSenders(chatID: 42, senders: [AllowedSender(handle: phone, name: "  ")]),
        ]
        harness.config = config
        let engine = try harness.engine()
        _ = await engine.ingestWatchLine(groupLine(
            id: 1, guid: "g-noname", text: "\u{1FA94} hi", sender: phoneNational
        ))
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.senderName, "sender")
        assertNoHandle(String(data: harness.webhook.bodies[0], encoding: .utf8) ?? "")
    }
}

private let payloadKeys: Set<String> = [
    "v", "event", "idempotency_key", "guid", "chat_id", "text", "created_at",
    "sender_is_me", "sender_name",
]

private struct DecodedPayload {
    var v: Int
    var senderIsMe: Bool
    var senderName: String
    var chatID: Int64
    var keys: Set<String>
}

private func payload(_ data: Data) throws -> DecodedPayload {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let chat = try XCTUnwrap(object["chat_id"] as? NSNumber)
    return DecodedPayload(
        v: try XCTUnwrap(object["v"] as? Int),
        senderIsMe: try XCTUnwrap(object["sender_is_me"] as? Bool),
        senderName: try XCTUnwrap(object["sender_name"] as? String),
        chatID: chat.int64Value,
        keys: Set(object.keys)
    )
}

private func assertNoHandle(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    for secret in ["09000000000", "090-0000-0000", "+81", "0000-0000", "example.com", "hana@"] {
        XCTAssertFalse(text.contains(secret), secret, file: file, line: line)
    }
}

private func renderedDiagnostics(_ harness: Harness) -> String {
    let logs = harness.log.records.map { record in
        "\(record.level) \(record.code) \(record.guid ?? "") \(record.detail ?? "")"
    }.joined(separator: "\n")
    let letters = harness.state.deadLetters.map { "\($0.error) \($0.guid ?? "")" }.joined(separator: "\n")
    return logs + "\n" + letters
}
