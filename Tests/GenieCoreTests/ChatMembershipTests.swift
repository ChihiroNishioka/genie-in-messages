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
            SenderHandle.normalize("09000000000"),
            SenderHandle.normalize("09000000001")
        )
        XCTAssertNil(SenderHandle.normalize("not-a-number"))
        XCTAssertNil(SenderHandle.normalize("   "))
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

final class SelfChatRuleTests: XCTestCase {
    func testGroupAndDirectChatAcceptTheOtherSide() {
        let mine = Set([SenderHandle.normalize("+81 90 0000 0000")!])
        XCTAssertFalse(SelfChat.ignoresInboundEcho(
            isGroup: true,
            chatID: 42,
            participantsKnown: false,
            participants: [],
            ownHandles: [],
            forcedSelfChatIDs: []
        ))
        XCTAssertFalse(SelfChat.ignoresInboundEcho(
            isGroup: false,
            chatID: 9,
            participantsKnown: true,
            participants: ["+81 70 0000 0002"],
            ownHandles: mine,
            forcedSelfChatIDs: []
        ))
        XCTAssertTrue(SelfChat.isSelfChat(
            isGroup: false,
            participantsKnown: true,
            participants: ["090-0000-0000"],
            ownHandles: mine
        ))
        XCTAssertTrue(SelfChat.ignoresInboundEcho(
            isGroup: false,
            chatID: 9,
            participantsKnown: true,
            participants: ["+81 70 0000 0002"],
            ownHandles: mine,
            forcedSelfChatIDs: [9]
        ))
        XCTAssertTrue(SelfChat.resolveGroup(
            flag: nil,
            chatGUID: "any;+;chat-fixture",
            chatIdentifier: nil
        ))
        XCTAssertFalse(SelfChat.resolveGroup(
            flag: false,
            chatGUID: "iMessage;-;+810900000000",
            chatIdentifier: "+810900000000"
        ))
    }

    func testEmptyOrUnknownParticipantsAreTheSafeSide() {
        let mine = Set([SenderHandle.normalize("+81 90 0000 0000")!])
        XCTAssertTrue(SelfChat.ignoresInboundEcho(
            isGroup: false, chatID: 7, participantsKnown: true, participants: [],
            ownHandles: mine, forcedSelfChatIDs: []
        ))
        XCTAssertTrue(SelfChat.ignoresInboundEcho(
            isGroup: false, chatID: 7, participantsKnown: true, participants: ["  "],
            ownHandles: mine, forcedSelfChatIDs: []
        ))
        XCTAssertTrue(SelfChat.ignoresInboundEcho(
            isGroup: false, chatID: 7, participantsKnown: false, participants: [],
            ownHandles: mine, forcedSelfChatIDs: []
        ))
        XCTAssertTrue(SelfChat.ignoresInboundEcho(
            isGroup: false, chatID: 9, participantsKnown: true, participants: ["+81 70 0000 0002"],
            ownHandles: [], forcedSelfChatIDs: []
        ))
        XCTAssertTrue(SelfChat.isHandle("+81 90 0000 0000", sender: "090-0000-0000"))
        XCTAssertTrue(SelfChat.isHandle("Hana@Example.com", sender: "hana@example.com"))
        XCTAssertTrue(SelfChat.isHandle("hana@example.com", sender: ""))
        XCTAssertTrue(SelfChat.isHandle("+81 90 0000 0000", sender: ""))
        XCTAssertTrue(SelfChat.isHandle("090-0000-0000", sender: ""))
        XCTAssertFalse(SelfChat.isHandle("hana", sender: ""))
        XCTAssertFalse(SelfChat.isHandle("hana", sender: "+81 90 0000 0000"))
    }
}

final class SenderNameConfigTests: XCTestCase {
    func testOldConfigDecodesWithoutTheNameMap() throws {
        let old = Data(#"{"webhook_url":"https://127.0.0.1/hook","marker":"ok"}"#.utf8)
        let config = try JSONDecoder().decode(GenieConfig.self, from: old)
        XCTAssertEqual(config.webhookURL, "https://127.0.0.1/hook")
        XCTAssertEqual(config.selfSenderName, "me")
        XCTAssertTrue(config.senderNames.isEmpty)
        XCTAssertTrue(config.selfChatIDs.isEmpty)
        XCTAssertNil(config.displayName(matching: "+81 90 0000 0000"))

        let blank = Data(#"{"self_sender_name":"  ","sender_names":null}"#.utf8)
        let blanked = try JSONDecoder().decode(GenieConfig.self, from: blank)
        XCTAssertEqual(blanked.selfSenderName, "me")
        XCTAssertTrue(blanked.senderNames.isEmpty)

        let named = Data(#"""
        {"sender_names":{
          "+81 90 0000 0000":"hana",
          "090-0000-0000":"later",
          "not a phone":"skip",
          "Hana@Example.com":"  "
        }}
        """#.utf8)
        let parsed = try JSONDecoder().decode(GenieConfig.self, from: named)
        XCTAssertEqual(parsed.displayName(matching: "090 0000 0000"), "hana")
        XCTAssertNil(parsed.displayName(matching: "hana@example.com"))
        XCTAssertNil(parsed.displayName(matching: "not a phone"))
    }

    func testExampleFileShowsTheNameMapWithoutPersonalValues() throws {
        let url = repoRoot().appendingPathComponent("config.example.json")
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("self_sender_name"))
        XCTAssertTrue(text.contains("sender_names"))
        XCTAssertFalse(text.contains("allowed_senders"))
        XCTAssertFalse(text.contains("@"))
        let config = try JSONDecoder().decode(GenieConfig.self, from: data)
        XCTAssertEqual(config.selfSenderName, "me")
        XCTAssertTrue(config.senderNames.isEmpty)
        XCTAssertTrue(config.selfChatIDs.isEmpty)
        XCTAssertTrue(text.contains("self_chat_ids"))
    }
}

final class ChatMembershipEngineTests: XCTestCase {
    private let phone = "+81 90 0000 0000"
    private let phoneNational = "090-0000-0000"
    private let other = "+81 70 0000 0002"
    private let mail = "hana@example.com"

    private func allow(_ harness: Harness, chat: Int64, names: [String: String] = [:], selfName: String = "me") {
        harness.allow.ids = [chat]
        harness.config.selfSenderName = selfName
        harness.config.senderNames = names
    }

    func testOnGroupReactsToAnotherMember() async throws {
        let harness = Harness()
        allow(harness, chat: 42, names: [phoneNational: "hana", "Hana@Example.com": "hana-mail"])
        let engine = try await harness.opened()
        let phoneResult = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-phone", chat: 42, fromMe: false, text: "\u{1FA94} hi",
            sender: phone, isGroup: true, participants: [phone, mail]
        ))
        let mailResult = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "g-mail", chat: 42, fromMe: false, text: "\u{1FA94}\u{FE0F} mail",
            sender: mail, isGroup: true, participants: [phone, mail]
        ))
        XCTAssertEqual(phoneResult, .delivered)
        XCTAssertEqual(mailResult, .delivered)
        let phoneBody = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(phoneBody.v, 1)
        XCTAssertEqual(phoneBody.senderIsMe, false)
        XCTAssertEqual(phoneBody.senderName, "hana")
        XCTAssertEqual(phoneBody.chatID, 42)
        XCTAssertEqual(phoneBody.keys, payloadKeys)
        assertNoHandle(String(data: harness.webhook.bodies[0], encoding: .utf8) ?? "")
        let mailBody = try payload(harness.webhook.bodies[1])
        XCTAssertEqual(mailBody.senderName, "hana-mail")
        XCTAssertEqual(mailBody.senderIsMe, false)
        let mailJSON = String(data: harness.webhook.bodies[1], encoding: .utf8) ?? ""
        XCTAssertFalse(mailJSON.lowercased().contains("example.com"))
        XCTAssertFalse(mailJSON.contains(mail))
    }

    func testOffChatIgnoresOwnLamp() async throws {
        let harness = Harness()
        let engine = try await harness.opened()
        let result = await engine.ingestWatchLine(watchLine(
            id: 8, guid: "g-off", chat: 3, fromMe: true, text: "\u{1FA94} QXOFF91"
        ))
        XCTAssertEqual(result, .ignoredNotAllowed)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        assertNoSecrets(renderedDiagnostics(harness), body: "QXOFF91")
    }

    func testSelfChatFalseSideStaysIgnored() async throws {
        let harness = Harness()
        allow(harness, chat: 7, names: [phone: "hana"])
        let engine = try await harness.opened()
        let text = "\u{1FA94} QXECHO91"
        let echo = await engine.ingestWatchLine(watchLine(
            id: 10, guid: "in", chat: 7, fromMe: false, text: text,
            sender: phone, isGroup: false, participants: []
        ))
        let mine = await engine.ingestWatchLine(watchLine(
            id: 11, guid: "out", chat: 7, fromMe: true, text: text
        ))
        XCTAssertEqual(echo, .ignoredNotFromMe)
        XCTAssertEqual(mine, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.senderIsMe, true)
        XCTAssertEqual(body.senderName, "me")
        assertNoSecrets(renderedDiagnostics(harness), body: "QXECHO91", handle: phone)
    }

    func testUnknownChatShapeIgnoresTheFalseSide() async throws {
        let harness = Harness()
        allow(harness, chat: 7)
        let engine = try await harness.opened()
        let echo = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "bare", chat: 7, fromMe: false, text: "\u{1FA94} hi", sender: phone
        ))
        XCTAssertEqual(echo, .ignoredNotFromMe)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        assertNoSecrets(renderedDiagnostics(harness), handle: phone)
    }

    func testDirectChatOtherPersonLamp() async throws {
        let harness = Harness()
        allow(harness, chat: 9)
        let engine = try await harness.engine()
        await learnDeviceChats(engine)
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-dm", chat: 9, fromMe: false, text: "\u{1FA94} dm",
            sender: other, isGroup: false, participants: [other],
            contactName: "hana"
        ))
        XCTAssertEqual(result, .delivered)
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.v, 1)
        XCTAssertEqual(body.senderIsMe, false)
        XCTAssertEqual(body.senderName, "hana")
        XCTAssertEqual(body.chatID, 9)
        XCTAssertEqual(body.keys, payloadKeys)
        assertNoHandle(String(data: harness.webhook.bodies[0], encoding: .utf8) ?? "")
    }

    func testNameMapDoesNotGateAndContactHandleIsDropped() async throws {
        let harness = Harness()
        allow(harness, chat: 42)
        let engine = try await harness.opened()
        let unnamed = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-empty", chat: 42, fromMe: false, text: "\u{1FA94} hi",
            sender: phone, isGroup: true, participants: [phone]
        ))
        let leaked = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "g-leak", chat: 42, fromMe: false, text: "\u{1FA94} next",
            sender: mail, isGroup: true, participants: [mail], contactName: "Hana@Example.com"
        ))
        XCTAssertEqual(unnamed, .delivered)
        XCTAssertEqual(leaked, .delivered)
        XCTAssertEqual(try payload(harness.webhook.bodies[0]).senderName, "")
        XCTAssertEqual(try payload(harness.webhook.bodies[1]).senderName, "")
        assertNoHandle(String(data: harness.webhook.bodies[0], encoding: .utf8) ?? "")
        let second = String(data: harness.webhook.bodies[1], encoding: .utf8) ?? ""
        XCTAssertFalse(second.lowercased().contains("example.com"))
    }

    func testEmptySenderDropsHandleShapedContactNames() async throws {
        let harness = Harness()
        allow(harness, chat: 42)
        let engine = try await harness.opened()
        let mailResult = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-mail-blank", chat: 42, fromMe: false, text: "\u{1FA94} mail",
            isGroup: true, participants: [mail], contactName: "hana@example.com"
        ))
        let phoneResult = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "g-phone-blank", chat: 42, fromMe: false, text: "\u{1FA94} phone",
            isGroup: true, participants: [phone], contactName: "+81 90 0000 0000"
        ))
        let named = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "g-name-blank", chat: 42, fromMe: false, text: "\u{1FA94} name",
            isGroup: true, participants: [phone], contactName: "hana"
        ))
        XCTAssertEqual(mailResult, .delivered)
        XCTAssertEqual(phoneResult, .delivered)
        XCTAssertEqual(named, .delivered)
        XCTAssertEqual(try payload(harness.webhook.bodies[0]).senderName, "")
        XCTAssertEqual(try payload(harness.webhook.bodies[1]).senderName, "")
        XCTAssertEqual(try payload(harness.webhook.bodies[2]).senderName, "hana")
        let joined = harness.webhook.bodies.map { String(data: $0, encoding: .utf8) ?? "" }.joined(separator: "\n")
        assertNoHandle(joined)
        XCTAssertFalse(joined.lowercased().contains("example.com"))
    }

    func testMappedNameWinsOverContactName() async throws {
        let harness = Harness()
        allow(harness, chat: 42, names: [phone: "hana"], selfName: "host")
        let engine = try await harness.opened()
        _ = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-map", chat: 42, fromMe: false, text: "\u{1FA94} hi",
            sender: phoneNational, isGroup: true, participants: [phone], contactName: "other"
        ))
        _ = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "g-me", chat: 42, fromMe: true, text: "\u{1FA94} mine",
            isGroup: true, participants: [phone]
        ))
        XCTAssertEqual(try payload(harness.webhook.bodies[0]).senderName, "hana")
        XCTAssertEqual(try payload(harness.webhook.bodies[0]).senderIsMe, false)
        XCTAssertEqual(try payload(harness.webhook.bodies[1]).senderName, "host")
        XCTAssertEqual(try payload(harness.webhook.bodies[1]).senderIsMe, true)
    }

    func testOldConfigStillReactsInsideAnOnChat() async throws {
        let old = Data(#"{"webhook_url":"https://127.0.0.1/webhook"}"#.utf8)
        let harness = Harness()
        harness.allow.ids = [42]
        harness.config = try JSONDecoder().decode(GenieConfig.self, from: old)
        let engine = try await harness.opened()
        let other = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-old", chat: 42, fromMe: false, text: "\u{1FA94} QXOLD91",
            sender: phone, isGroup: true, participants: [phone]
        ))
        XCTAssertEqual(other, .delivered)
        let body = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(body.v, 1)
        XCTAssertEqual(body.senderIsMe, false)
        XCTAssertEqual(body.senderName, "")
        assertNoSecrets(renderedDiagnostics(harness), body: "QXOLD91", handle: phone)
        assertNoHandle(String(data: harness.webhook.bodies[0], encoding: .utf8) ?? "")
    }

    func testLampInTheMiddleTapbackAndAttachmentOnlyAreIgnored() async throws {
        let harness = Harness()
        allow(harness, chat: 42)
        let engine = try await harness.opened()
        let middle = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-mid", chat: 42, fromMe: false, text: "see \u{1FA94} later",
            sender: phone, isGroup: true, participants: [phone]
        ))
        let end = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "g-end", chat: 42, fromMe: false, text: "end \u{1FA94}",
            sender: phone, isGroup: true, participants: [phone]
        ))
        let reaction = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "g-tap", chat: 42, fromMe: false, text: "\u{1FA94}",
            reaction: true, sender: phone, isGroup: true, participants: [phone]
        ))
        let attachment = await engine.ingestWatchLine(watchLine(
            id: 4, guid: "g-file", chat: 42, fromMe: false, text: "",
            sender: phone, isGroup: true, participants: [phone], attachments: true
        ))
        let caption = await engine.ingestWatchLine(watchLine(
            id: 5, guid: "g-cap", chat: 42, fromMe: false, text: "\u{1FA94} pic",
            sender: phone, isGroup: true, participants: [phone], attachments: true
        ))
        XCTAssertEqual(middle, .ignoredNoSignal)
        XCTAssertEqual(end, .ignoredNoSignal)
        XCTAssertEqual(reaction, .ignoredReaction)
        XCTAssertEqual(attachment, .ignoredNoSignal)
        XCTAssertEqual(caption, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
    }

    func testOtherMemberGenieMarkerDoesNotTrigger() async throws {
        let harness = Harness()
        allow(harness, chat: 42)
        let engine = try await harness.opened()
        let marker = GenieConfig.productDefaults.marker
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-marker", chat: 42, fromMe: false, text: marker + " hello",
            sender: phone, isGroup: true, participants: [phone]
        ))
        XCTAssertEqual(result, .ignoredNoSignal)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
    }

    func testSameGroupMessageIsNotDeliveredTwice() async throws {
        let harness = Harness()
        allow(harness, chat: 42)
        harness.state.state.sentGUIDs = ["g-sent"]
        let engine = try await harness.opened()
        let first = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-same", chat: 42, fromMe: false, text: "\u{1FA94} once",
            sender: phone, isGroup: true, participants: [phone]
        ))
        let second = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "g-same", chat: 42, fromMe: false, text: "\u{1FA94} once",
            sender: phone, isGroup: true, participants: [phone]
        ))
        let sent = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "g-sent", chat: 42, fromMe: false, text: "\u{1FA94} echo",
            sender: phone, isGroup: true, participants: [phone]
        ))
        XCTAssertEqual(first, .delivered)
        XCTAssertEqual(second, .duplicate)
        XCTAssertEqual(sent, .ignoredSentGUID)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
    }

    func testGroupGuidWithoutTheFlagStillAcceptsTheOtherSide() async throws {
        let harness = Harness()
        allow(harness, chat: 42)
        harness.allow.guids[42] = "any;+;chat-fixture"
        let engine = try await harness.opened()
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "g-plus", chat: 42, fromMe: false, text: "\u{1FA94} hi",
            chatGUID: "any;+;chat-fixture", sender: phone
        ))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(try payload(harness.webhook.bodies[0]).senderIsMe, false)
    }

    func testReplyGoesToTheSameChat() async throws {
        let harness = Harness()
        allow(harness, chat: 42)
        harness.config.replyFetchURL = "https://127.0.0.1/replies"
        let engine = try await harness.opened()
        let result = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "msg-1", chat: 42, fromMe: false, text: "\u{1FA94} hi",
            sender: phone, isGroup: true, participants: [phone]
        ))
        XCTAssertEqual(result, .delivered)
        harness.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 42, text: "ok", guid: "msg-1")], nextCursor: nil),
        ]
        await engine.pollReplies()
        XCTAssertEqual(harness.sender.sent.map(\.chatID), [42, 42])
    }

    func testDeviceChatsDistinguishSelfDirectAndGroup() async throws {
        let parsed = ChatListParser.parse(ndjson: deviceChatsNDJSON)
        XCTAssertEqual(parsed.failedLineCount, 0)
        XCTAssertEqual(parsed.chats.map(\.id), [7, 9, 42])
        XCTAssertEqual(parsed.chats.map(\.title), ["トーク 7", "hana", "family"])
        XCTAssertEqual(parsed.chats.map(\.participants.count), [1, 1, 3])
        for chat in parsed.chats {
            XCTAssertFalse(chat.title.contains("90"))
            XCTAssertFalse(chat.title.contains("70"))
            XCTAssertFalse(chat.title.contains("555"))
        }
        let handles = SelfChat.ownHandleKeys(in: parsed.chats)
        XCTAssertEqual(handles, [SenderHandle.normalize(phone)!])
        XCTAssertTrue(SelfChat.isSelfChat(
            isGroup: parsed.chats[0].isGroup,
            participantsKnown: true,
            participants: parsed.chats[0].participants,
            ownHandles: handles
        ))
        XCTAssertFalse(SelfChat.isSelfChat(
            isGroup: parsed.chats[1].isGroup,
            participantsKnown: true,
            participants: parsed.chats[1].participants,
            ownHandles: handles
        ))

        let harness = Harness()
        harness.allow.ids = [7, 9, 42]
        let engine = try await harness.engine()
        await engine.showChats(parsed.chats)

        let echo = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "self-false", chat: 7, fromMe: false, text: "\u{1FA94} QXSELF91",
            sender: phone, isGroup: false, participants: [phone]
        ))
        let mine = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "self-true", chat: 7, fromMe: true, text: "\u{1FA94} QXSELF91",
            isGroup: false, participants: [phone]
        ))
        let direct = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "direct-false", chat: 9, fromMe: false, text: "\u{1FA94} hello",
            sender: other, isGroup: false, participants: [other]
        ))
        let group = await engine.ingestWatchLine(watchLine(
            id: 4, guid: "group-false", chat: 42, fromMe: false, text: "\u{1FA94} family",
            sender: other, isGroup: true, participants: [other, "080-0000-0001", "+1 555 010 0000"]
        ))
        XCTAssertEqual(echo, .ignoredNotFromMe)
        XCTAssertEqual(mine, .delivered)
        XCTAssertEqual(direct, .delivered)
        XCTAssertEqual(group, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 3)
        let selfBody = try payload(harness.webhook.bodies[0])
        XCTAssertEqual(selfBody.senderIsMe, true)
        XCTAssertEqual(selfBody.chatID, 7)
        XCTAssertEqual(try payload(harness.webhook.bodies[1]).chatID, 9)
        XCTAssertEqual(try payload(harness.webhook.bodies[1]).senderIsMe, false)
        XCTAssertEqual(try payload(harness.webhook.bodies[2]).chatID, 42)
        let dumped = harness.webhook.bodies.map { String(data: $0, encoding: .utf8) ?? "" }.joined(separator: "\n")
        assertNoHandle(dumped)
        assertNoSecrets(renderedDiagnostics(harness), body: "QXSELF91", handle: phone)
        assertNoSecrets(renderedDiagnostics(harness), handle: other)
    }

    func testSelfChatIDsOverrideANormalDirectChat() async throws {
        let harness = Harness()
        harness.allow.ids = [9]
        harness.config.selfChatIDs = [9]
        let engine = try await harness.engine()
        await learnDeviceChats(engine)
        let echo = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "forced-false", chat: 9, fromMe: false, text: "\u{1FA94} QXFORCE91",
            sender: other, isGroup: false, participants: [other]
        ))
        let mine = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "forced-true", chat: 9, fromMe: true, text: "\u{1FA94} QXFORCE91"
        ))
        XCTAssertEqual(echo, .ignoredNotFromMe)
        XCTAssertEqual(mine, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 1)
        XCTAssertEqual(try payload(harness.webhook.bodies[0]).senderIsMe, true)
        assertNoSecrets(renderedDiagnostics(harness), body: "QXFORCE91", handle: other)
    }

    func testUnreadableChatsStayOnTheSafeSide() async throws {
        let harness = Harness()
        allow(harness, chat: 9)
        let engine = try await harness.opened()
        await engine.applyChatList(.failed)
        _ = await engine.applyChatList(.parsed(ChatListParse(chats: [], failedLineCount: 1)))
        let echo = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "unread", chat: 9, fromMe: false, text: "\u{1FA94} QXMISS91",
            sender: other, isGroup: false, participants: [other]
        ))
        XCTAssertEqual(echo, .ignoredNotFromMe)
        XCTAssertTrue(harness.webhook.bodies.isEmpty)
        XCTAssertEqual(harness.log.records.filter { $0.code == "chats_failed" }.count, 1)
        XCTAssertEqual(harness.log.records.filter { $0.code == "chats_parse_failed" }.count, 1)
        assertNoSecrets(renderedDiagnostics(harness), body: "QXMISS91", handle: other)

        let broken = """
        {"id":9,"is_group":false,"participants":["\(other)"],"last_addressed_handle":"\(phone)"}
        {not-json \(phone)
        """
        let parsed = ChatListParser.parse(ndjson: broken)
        XCTAssertEqual(parsed.failedLineCount, 1)
        XCTAssertEqual(parsed.chats.count, 1)
        await engine.showChats(parsed.chats)
        let after = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "after", chat: 9, fromMe: false, text: "\u{1FA94} later",
            sender: other, isGroup: false, participants: [other]
        ))
        XCTAssertEqual(after, .delivered)
        await engine.applyChatList(.failed)
        let kept = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "kept", chat: 9, fromMe: false, text: "\u{1FA94} kept",
            sender: other, isGroup: false, participants: [other]
        ))
        XCTAssertEqual(kept, .delivered)
        assertNoSecrets(renderedDiagnostics(harness), handle: phone)
    }

    func testWatchLineCallerIDIdentifiesSelfWithoutChats() async throws {
        let harness = Harness()
        harness.allow.ids = [7, 9]
        let engine = try await harness.opened()
        let mine = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "out", chat: 7, fromMe: true, text: "\u{1FA94} mine",
            isGroup: false, participants: [phone], destinationCallerID: phoneNational
        ))
        let echo = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "echo", chat: 7, fromMe: false, text: "\u{1FA94} mine",
            sender: phone, isGroup: false, participants: [phone]
        ))
        let direct = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "dm", chat: 9, fromMe: false, text: "\u{1FA94} dm",
            sender: other, isGroup: false, participants: [other]
        ))
        XCTAssertEqual(mine, .delivered)
        XCTAssertEqual(echo, .ignoredNotFromMe)
        XCTAssertEqual(direct, .delivered)
        XCTAssertEqual(harness.webhook.bodies.count, 2)
        assertNoHandle(harness.webhook.bodies.map { String(data: $0, encoding: .utf8) ?? "" }.joined())
        assertNoSecrets(renderedDiagnostics(harness), handle: phone)
    }

    private func learnDeviceChats(_ engine: GenieEngine) async {
        let parsed = ChatListParser.parse(ndjson: deviceChatsNDJSON)
        await engine.showChats(parsed.chats)
    }
}

private let deviceChatsNDJSON = """
{"id":7,"name":"","is_group":false,"identifier":"+81 90 0000 0000","guid":"iMessage;-;self","participants":["+81 90 0000 0000"],"last_addressed_handle":"+81 90 0000 0000"}
{"id":9,"name":"hana","is_group":false,"identifier":"+81 70 0000 0002","guid":"iMessage;-;hana","participants":["+81 70 0000 0002"],"last_addressed_handle":"090-0000-0000"}
{"id":42,"name":"family","is_group":true,"identifier":"any;+;chat-fixture","guid":"iMessage;+;chat-fixture","participants":["+81 70 0000 0002","080-0000-0001","+1 555 010 0000"],"last_addressed_handle":"+81 90 0000 0000"}
"""

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

private func assertNoSecrets(
    _ text: String,
    body: String? = nil,
    handle: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if let body {
        XCTAssertFalse(text.contains(body), file: file, line: line)
    }
    if let handle {
        XCTAssertFalse(text.contains(handle), file: file, line: line)
        XCTAssertFalse(text.contains("+81"), file: file, line: line)
    }
}

private func renderedDiagnostics(_ harness: Harness) -> String {
    let logs = harness.log.records.map { record in
        "\(record.level) \(record.code) \(record.guid ?? "") \(record.detail ?? "")"
    }.joined(separator: "\n")
    let letters = harness.state.deadLetters.map { "\($0.error) \($0.guid ?? "")" }.joined(separator: "\n")
    return logs + "\n" + letters
}
