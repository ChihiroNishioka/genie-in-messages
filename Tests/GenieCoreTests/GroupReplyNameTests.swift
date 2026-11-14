import Foundation
import XCTest
@testable import GenieCore

final class GroupReplyNameTests: XCTestCase {
    private let groupGUID = "iMessage;+;chat000000000000000001"
    private let directGUID = "iMessage;-;family@example.com"
    private let sender = "family@example.com"

    func testConfiguredGroupNamePrefixesOnlyTheBodyAndStaysPrivate() async throws {
        let (h, provider, engine) = try await openGroup(names: ["Family@Example.com": " まひろ "])
        let received = await engine.ingestWatchLine(groupSignal())
        XCTAssertEqual(received, .delivered)

        let stateBeforeReply = try stateText(h)
        XCTAssertTrue(stateBeforeReply.contains("\"addressee\":\"まひろ\""))
        XCTAssertFalse(stateBeforeReply.localizedCaseInsensitiveContains(sender))

        provider.config.senderNames = [sender: "りん"]
        queueReply(h, text: "answer")
        _ = await engine.pollReplies()

        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "まひろへ：answer"])
        assertPrivateReplyData(h)
    }

    func testMissingNameDoesNotFallBackToContactName() async throws {
        for names in [[:], ["other@example.com": "まひろ"]] as [[String: String]] {
            let (h, _, engine) = try await openGroup(names: names)
            _ = await engine.ingestWatchLine(groupSignal(contactName: "まひろ"))
            queueReply(h, text: "answer")
            _ = await engine.pollReplies()
            XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
        }
    }

    func testOneToOneReplyDoesNotUseConfiguredName() async throws {
        let (h, engine) = try await openDirect(names: [sender: "まひろ"])
        let received = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "incoming-direct", chat: 42, fromMe: false, text: "🪔 request",
            chatGUID: directGUID, sender: sender, isGroup: false,
            participants: [sender], destinationCallerID: "owner@example.com"
        ))
        XCTAssertEqual(received, .delivered)
        queueReply(h, origin: "incoming-direct", text: "answer")
        _ = await engine.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
        XCTAssertFalse(try stateText(h).contains("まひろ"))
    }

    func testOwnGroupSignalDoesNotStoreOrUseConfiguredName() async throws {
        let (h, _, engine) = try await openGroup(names: [sender: "まひろ"])
        let received = await engine.ingestWatchLine(groupSignal(fromMe: true))
        XCTAssertEqual(received, .delivered)
        queueReply(h, text: "answer")
        _ = await engine.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
        XCTAssertFalse(try stateText(h).contains("まひろ"))
    }

    func testSelfChatDoesNotStoreOrUseConfiguredName() async throws {
        let (h, engine) = try await openDirect(names: [sender: "まひろ"], selfChatIDs: [42])
        let received = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "incoming-self-chat", chat: 42, fromMe: true, text: "🪔 request",
            chatGUID: directGUID, sender: sender, isGroup: false
        ))
        XCTAssertEqual(received, .delivered)
        queueReply(h, origin: "incoming-self-chat", text: "answer")
        _ = await engine.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
        XCTAssertFalse(try stateText(h).contains("まひろ"))
    }

    func testUnsafeConfiguredNamesAreNotStoredOrSent() async throws {
        let unsafeNames = [
            " ", "line\nbreak", String(repeating: "あ", count: 21), sender, "090-0000-0000",
            "1-800-FLOWERS", "+name", "name1234567", "🪔パパ"
        ]
        for name in unsafeNames {
            let (h, _, engine) = try await openGroup(names: [sender: name])
            _ = await engine.ingestWatchLine(groupSignal())
            queueReply(h, text: "answer")
            _ = await engine.pollReplies()
            XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"], "name: \(name)")
            let state = try stateText(h)
            XCTAssertFalse(state.contains(name))
            XCTAssertFalse(state.localizedCaseInsensitiveContains(sender))
            XCTAssertFalse(state.contains("090-0000-0000"))
        }
    }

    func testHanNameWithDigitRemainsAValidAddressee() async throws {
        let name = "はるも2"
        let (h, _, engine) = try await openGroup(names: [sender: name])
        _ = await engine.ingestWatchLine(groupSignal())
        queueReply(h, text: "answer")
        _ = await engine.pollReplies()

        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "\(name)へ：answer"])
        XCTAssertTrue(try stateText(h).contains("\"addressee\":\"\(name)\""))
    }

    func testConfiguredAndDefaultReplyMarkersAreNotValidAddressees() async throws {
        let fixtures = [
            (name: ReplyComposer.markerText + "パパ", marker: "🦉"),
            (name: "🦉パパ", marker: "🦉"),
            (name: "🦉パパ", marker: "🦉パパへ：")
        ]
        for fixture in fixtures {
            let (h, _, engine) = try await openGroup(names: [sender: fixture.name], replyMarker: fixture.marker)
            _ = await engine.ingestWatchLine(groupSignal())
            queueReply(h, text: "answer")
            _ = await engine.pollReplies()

            XCTAssertEqual(h.sender.sent.map(\.text), [fixture.marker, "answer"], "name: \(fixture.name)")
            XCTAssertFalse(try stateText(h).contains(fixture.name))
        }
    }

    func testStoredUnsafeAddresseeCannotMakeDeliveredBodyStartWithControlPrefix() async throws {
        let fixtures = [
            (name: "🪔パパ", marker: "🦉", body: "answer"),
            (name: ReplyComposer.markerText + "パパ", marker: "🦉", body: "answer"),
            (name: "🦉パパ", marker: "🦉", body: "answer"),
            (name: "🦉パパ", marker: "🦉パパへ：答", body: "答")
        ]
        for fixture in fixtures {
            let (h, engine) = try await openGroupWithStoredRoute(
                addressee: fixture.name,
                replyMarker: fixture.marker
            )
            queueReply(h, text: fixture.body)
            _ = await engine.pollReplies()

            XCTAssertEqual(h.sender.sent.map(\.text), [fixture.marker, fixture.body], "name: \(fixture.name)")
        }
    }

    func testUnnormalizableSenderDoesNotUseContactName() async throws {
        let (h, _, engine) = try await openGroup(names: [sender: "まひろ"])
        _ = await engine.ingestWatchLine(watchLine(
            id: 1, guid: "incoming-1", chat: 42, fromMe: false, text: "🪔 request",
            chatGUID: groupGUID, sender: "unknown sender", isGroup: true,
            participants: [sender], contactName: "まひろ"
        ))
        queueReply(h, text: "answer")
        _ = await engine.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
    }

    func testAlreadyPrefixedBodyIsNotPrefixedTwice() async throws {
        let (h, _, engine) = try await openGroup(names: [sender: "まひろ"])
        _ = await engine.ingestWatchLine(groupSignal())
        queueReply(h, text: "まひろへ：answer")
        _ = await engine.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "まひろへ：answer"])
    }

    func testBodyResendKeepsTheAddresseeAndDoesNotResendTheMarker() async throws {
        let (h, _, engine) = try await openGroup(names: [sender: "まひろ"])
        h.sender.script = [
            .success(SendReceipt(id: 1, guid: "marker", status: "sent")),
            .failure(.failed),
            .success(SendReceipt(id: 3, guid: "body-resend", status: "sent"))
        ]
        _ = await engine.ingestWatchLine(groupSignal())
        queueReply(h, text: "answer")
        _ = await engine.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [
            ReplyComposer.markerText, "まひろへ：answer", "まひろへ：answer"
        ])
    }

    func testOldRouteWithoutAddresseeDecodesAndSendsWithoutPrefix() async throws {
        let h = splitHarness("answer", chat: 7, origin: "old-origin")
        let old = Data(#"{"routes":[{"guid":"old-origin","chat_id":7,"at":1700000000000}]}"#.utf8)
        h.state.state = try StateCoding.decoder().decode(PersistedState.self, from: old)
        h.replies.pages = [ReplyPage(replies: [routedReply("reply-1", chat: 7, text: "answer", guid: "old-origin")], nextCursor: nil)]

        guard let engine = await splitOpened(h) else { return }
        await engine.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [ReplyComposer.markerText, "answer"])
    }

    private func openGroup(
        names: [String: String], selfChatIDs: [Int64] = [], replyMarker: String? = nil
    ) async throws -> (Harness, MutableConfig, GenieEngine) {
        let h = Harness()
        var config = GenieConfig.productDefaults
        config.groupChatGUIDs = [groupGUID]
        config.webhookURL = "https://127.0.0.1/webhook"
        config.replyFetchURL = "https://127.0.0.1/replies"
        config.senderNames = names
        config.selfChatIDs = selfChatIDs
        if let replyMarker { config.replyMarker = replyMarker }
        h.config = config
        let provider = MutableConfig(config)
        let engine = try makeEngine(h, provider: provider, config: config)
        await engine.showChats([ChatSummary(id: 42, title: "family", isGroup: true, guid: groupGUID)])
        return (h, provider, engine)
    }

    private func openGroupWithStoredRoute(
        addressee: String, replyMarker: String
    ) async throws -> (Harness, GenieEngine) {
        let h = Harness()
        var config = GenieConfig.productDefaults
        config.groupChatGUIDs = [groupGUID]
        config.webhookURL = "https://127.0.0.1/webhook"
        config.replyFetchURL = "https://127.0.0.1/replies"
        config.replyMarker = replyMarker
        h.config = config
        h.state.state.routes = [MessageRoute(
            guid: "incoming-1", chatID: 42, at: h.clock.current, addressee: addressee
        )]
        let engine = try makeEngine(h, provider: MutableConfig(config), config: config)
        await engine.showChats([ChatSummary(id: 42, title: "family", isGroup: true, guid: groupGUID)])
        return (h, engine)
    }

    private func openDirect(
        names: [String: String], selfChatIDs: [Int64] = []
    ) async throws -> (Harness, GenieEngine) {
        let h = Harness()
        var config = GenieConfig.productDefaults
        config.webhookURL = "https://127.0.0.1/webhook"
        config.replyFetchURL = "https://127.0.0.1/replies"
        config.senderNames = names
        config.selfChatIDs = selfChatIDs
        h.config = config
        h.allow.ids = [42]
        h.allow.guids[42] = directGUID
        let engine = try makeEngine(h, provider: MutableConfig(config), config: config)
        await engine.showChats([ChatSummary(id: 42, title: "direct", isGroup: false, guid: directGUID)])
        return (h, engine)
    }

    private func makeEngine(_ h: Harness, provider: MutableConfig, config: GenieConfig) throws -> GenieEngine {
        try GenieEngine(
            configProvider: provider, initialConfig: config, stateStore: h.store ?? h.state,
            allowlistStore: h.allow, replySource: h.replies, httpReplySource: h.httpReplies,
            sender: h.sender, webhook: h.webhook, secrets: h.secrets, lock: h.lock,
            clock: h.clock, log: h.log, stop: h.stop
        )
    }

    private func groupSignal(fromMe: Bool = false, contactName: String? = nil) -> String {
        watchLine(id: 1, guid: "incoming-1", chat: 42, fromMe: fromMe, text: "🪔 request",
            chatGUID: groupGUID, sender: sender, isGroup: true, participants: [sender], contactName: contactName)
    }

    private func queueReply(_ h: Harness, origin: String = "incoming-1", chat: Int64 = 42, text: String) {
        h.replies.pages = [ReplyPage(replies: [routedReply("reply-1", chat: chat, text: text, guid: origin)], nextCursor: nil)]
    }

    private func stateText(_ h: Harness) throws -> String {
        String(data: try StateCoding.encoder().encode(h.state.state), encoding: .utf8) ?? ""
    }

    private func assertPrivateReplyData(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let state = (try? stateText(h)) ?? ""
        let logs = h.log.records.map { "\($0.code) \($0.detail ?? "")" }.joined(separator: "\n")
        let deadLetters = h.state.deadLetters.map { "\($0.error) \($0.kind)" }.joined(separator: "\n")
        let sent = h.sender.sent.map(\.text).joined(separator: "\n")
        for text in [state, logs, deadLetters, sent] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(sender), file: file, line: line)
            XCTAssertFalse(text.contains("090-0000-0000"), file: file, line: line)
        }
    }
}
