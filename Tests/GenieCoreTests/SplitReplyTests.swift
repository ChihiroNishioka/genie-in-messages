import Foundation
import XCTest
@testable import GenieCore

let M = "\u{1F9DE}\u{200D}\u{2642}\u{FE0F}"
let B = "こんにちは"

final class SplitReplyTests: XCTestCase {
    func testFirstMessageIsExactlyTheFourScalars() async {
        let h = splitHarness(M + " " + B)
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 2)
        guard h.sender.sent.count >= 1 else { XCTFail("first send missing"); return }
        XCTAssertEqual(Array(h.sender.sent[0].text.utf8), [0xF0, 0x9F, 0xA7, 0x9E, 0xE2, 0x80, 0x8D, 0xE2, 0x99, 0x82, 0xEF, 0xB8, 0x8F])
        XCTAssertEqual(h.sender.sent[0].text.unicodeScalars.map(\.value), [0x1F9DE, 0x200D, 0x2642, 0xFE0F])
    }

    func testSecondMessageHasNoMarkerOrLeadingSpace() async {
        let inputs = [M + " " + B, M + "　" + B, M + "\n" + B, M + B, B, "🧞‍♂" + B, "  " + M + " \n " + B, M + M + " " + B]
        for input in inputs {
            let h = splitHarness(input)
            guard let e = await splitOpened(h) else { return }
            await e.pollReplies()
            XCTAssertEqual(h.sender.sent.map(\.text), [M, B], "input: \(input)")
            guard h.sender.sent.count >= 2 else { XCTFail("two sends missing"); return }
            XCTAssertTrue(h.sender.sent.allSatisfy { $0.chatID == 7 })
            let first = h.sender.sent[1].text.unicodeScalars.first
            XCTAssertFalse(first.map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? true)
            XCTAssertNotEqual(first?.value, 0x1F9DE)
        }
    }

    func testSavesHappenInOrder() async {
        let h = splitHarness()
        let recorder = RecordingStateStore(state: h.state.state)
        h.store = recorder
        guard let e = await splitOpened(h) else { return }
        var secondSendSawS3 = false
        h.sender.onSend = {
            if h.sender.sent.count == 2, let saved = recorder.saves.last,
               let json = self.splitJSON(saved),
               let partial = (json["partial_replies"] as? [[String: Any]])?.first,
               let pending = json["pending_sends"] as? [[String: Any]] {
                secondSendSawS3 = partial["reply_id"] as? String == "r1"
                    && partial["marker_guid"] as? String == "sent-1"
                    && partial["body_resends"] as? Int == 0
                    && pending.contains { $0["reply_id"] as? String == "r1" && $0["part"] as? String == "body" }
            }
        }
        await e.pollReplies()
        let states = recorder.saves.compactMap { splitJSON($0) }
        let s1 = states.firstIndex { state in
            (state["partial_replies"] as? [[String: Any]] ?? []).isEmpty
                && (state["pending_sends"] as? [[String: Any]] ?? []).contains { $0["part"] as? String == "marker" }
        }
        let s2 = states.firstIndex { state in
            (state["pending_sends"] as? [[String: Any]] ?? []).isEmpty
                && (state["partial_replies"] as? [[String: Any]] ?? []).contains { $0["marker_guid"] as? String == "sent-1" }
                && (state["sent_guids"] as? [String] ?? []).contains("sent-1")
        }
        let s3 = states.firstIndex { state in
            !(state["partial_replies"] as? [[String: Any]] ?? []).isEmpty
                && (state["pending_sends"] as? [[String: Any]] ?? []).contains { $0["part"] as? String == "body" }
        }
        let s4 = states.firstIndex { state in
            (state["partial_replies"] as? [[String: Any]] ?? []).isEmpty
                && (state["pending_sends"] as? [[String: Any]] ?? []).isEmpty
                && (state["handled_reply_ids"] as? [String] ?? []).contains("r1")
        }
        guard let s1, let s2, let s3, let s4 else { XCTFail("S1 through S4 saves missing"); return }
        XCTAssertLessThan(s1, s2)
        XCTAssertLessThan(s2, s3)
        XCTAssertLessThan(s3, s4)
        XCTAssertTrue(secondSendSawS3)
    }

    func testMarkerNotStartedKeepsTheBodyInTheHold() async {
        let h = splitHarness()
        h.sender.script = [.failure(.notStarted), .success(SendReceipt(id: 2, guid: "marker-again", status: "sent")), .success(SendReceipt(id: 3, guid: "body", status: "sent"))]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        let first = await e.snapshot()
        XCTAssertEqual(first.heldLockCount, 1)
        XCTAssertEqual(first.lastError, "apple_event_1712")
        XCTAssertTrue(h.state.state.rateEvents.isEmpty)
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, M, B])
    }

    func testMarkerUncertainSendsNoBody() async {
        let h = splitHarness()
        h.sender.script = [.failure(.uncertain)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        XCTAssertEqual(h.state.deadLetters.first?.error, "send_uncertain")
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 1)
        XCTAssertTrue(h.log.records.contains { $0.code == "send_uncertain" && $0.detail == "marker" })
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testMarkerFailedSendsNoBody() async {
        let h = splitHarness()
        h.sender.script = [.failure(.failed)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        XCTAssertEqual(h.state.deadLetters.first?.error, "send_failed")
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue(h.state.state.rateEvents.isEmpty)
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testBodyNotStartedDoesNotUseTheResend() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.notStarted), .failure(.failed), .success(SendReceipt(id: 4, guid: "body-again", status: "sent"))]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B])
        let waiting = await e.snapshot()
        XCTAssertEqual(waiting.heldCount, 1)
        XCTAssertEqual((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).first?["body_resends"] as? Int, 0)
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B, B])
        XCTAssertTrue(h.state.deadLetters.isEmpty)
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 1)
        XCTAssertEqual(h.log.records.filter { $0.code == "apple_event_1712" && $0.detail == "body" }.count, 1)
    }

    func testFailedResendGoesToDeadLetter() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.failed), .failure(.failed)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        await e.retryHolds()
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B])
        XCTAssertTrue(h.state.deadLetters.contains { $0.error == "body_send_failed" })
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testLockBeforeTheBodyHoldsOnlyTheBody() async {
        let h = splitHarness()
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = { if h.sender.sent.count == 1 { h.lock.locked = true } }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        let locked = await e.snapshot()
        XCTAssertEqual(locked.heldLockCount, 1)
        XCTAssertEqual(locked.lastError, "screen_locked")
        XCTAssertEqual((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).first?["body_resends"] as? Int, 0)
        h.sender.onSend = nil
        h.lock.locked = false
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B])
    }

    func testRateCountsOnePerReply() async {
        let h = Harness()
        h.allow.ids = [7]
        h.config.replyFetchURL = "https://example.com/replies"
        h.config.rateLimitCount = 5
        h.config.rateLimitWindowSeconds = 60
        for n in 1...7 { seedRoute(h, guid: "origin-\(n)", chat: 7) }
        h.replies.pages = [ReplyPage(replies: (1...6).map { n in routedReply("r\(n)", chat: 7, text: "body-\(n)", guid: "origin-\(n)") }, nextCursor: nil)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 10)
        XCTAssertEqual(h.state.state.haltedChatIDs, [7])
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 5)
        h.clock.current = h.clock.current.addingTimeInterval(61)
        h.replies.pages = [ReplyPage(replies: [routedReply("r7", chat: 7, text: "body-7", guid: "origin-7")], nextCursor: nil)]
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 10)
        await e.resumeRateLimit(chatID: 7)
        XCTAssertEqual(h.sender.sent.count, 14)
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 2)
        XCTAssertFalse(h.state.state.haltedChatIDs.contains(7))
    }

    func testBodyIsSentEvenWhenTheChatIsHalted() async {
        let h = splitHarness()
        h.state.state.haltedChatIDs = [7]
        h.state.state.rateEvents = (0..<5).map { _ in RateEvent(chatID: 7, at: h.clock.current) }
        guard splitInstallPartials(h, [splitPartial("r1")]), let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [B])
    }

    func testPauseBetweenPartsHoldsTheBody() async {
        let h = splitHarness()
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = { if h.sender.sent.count == 1 { await e.setPaused(true) } }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        let paused = await e.snapshot()
        XCTAssertEqual(paused.heldCount, 1)
        await e.setPaused(false)
        h.sender.onSend = nil
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B])
    }

    func testStopBetweenPartsResumesAfterRestartFromJSON() async {
        let h = splitHarness()
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = { if h.sender.sent.count == 1 { h.stop.stop() } }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        do {
            let (state, json) = try reloaded(h.state.state)
            XCTAssertTrue(json.contains("\"partial_replies\""))
            XCTAssertTrue(json.contains("\"marker_guid\":\"sent-1\""))
            XCTAssertTrue(json.contains("\"body_resends\":0"))
            let restarted = Harness()
            restarted.allow.ids = [7]
            restarted.config.replyFetchURL = "https://example.com/replies"
            restarted.state.state = state
            restarted.replies.pages = [ReplyPage(replies: [routedReply("r1", chat: 7, text: B, guid: "origin")], nextCursor: nil)]
            guard let next = await splitOpened(restarted) else { return }
            await next.pollReplies()
            XCTAssertEqual(restarted.sender.sent.map(\.text), [B])
        } catch { XCTFail("state reload failed: \(error)") }
    }

    func testDisabledBetweenPartsDropsTheBody() async {
        let h = splitHarness()
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = { if h.sender.sent.count == 1 { await e.setChatEnabled(7, enabled: false) } }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue(h.log.records.contains { $0.code == "reply_chat_disabled" && $0.detail == "body" })
        XCTAssertFalse((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).contains { $0["reply_id"] as? String == "r1" })
    }

    func testInterruptedMarkerIsNotRetried() async {
        let h = splitHarness()
        let pending: [[String: Any]] = [["reply_id": "r1", "chat_id": 7, "hash": "abc", "at": 1_700_000_000_000, "rate_counted": false, "part": "marker"]]
        guard splitInstallPartials(h, [], pending: pending), let e = await splitOpened(h) else { return }
        let savedPending = splitJSON(h.state.state)?["pending_sends"] as? [[String: Any]] ?? []
        XCTAssertTrue(savedPending.isEmpty)
        await e.pollReplies()
        XCTAssertTrue(h.sender.sent.isEmpty)
        XCTAssertTrue(h.state.deadLetters.contains { $0.error == "send_interrupted" })
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
    }

    func testOldStateWithoutPartsDecodes() async {
        let raw = "{\"v\":1,\"pending_sends\":[{\"reply_id\":\"r\",\"chat_id\":1,\"hash\":\"h\",\"at\":0}]}"
        guard let data = raw.data(using: .utf8) else { XCTFail("fixture encoding failed"); return }
        do {
            let state = try StateCoding.decoder().decode(PersistedState.self, from: data)
            XCTAssertEqual(state.pendingSends.count, 1)
            guard let first = state.pendingSends.first else { XCTFail("pending send missing"); return }
            XCTAssertFalse(first.rateCounted)
            XCTAssertTrue((splitJSON(state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
            let oldPartial = "{\"v\":1,\"partial_replies\":[{\"reply_id\":\"r\",\"chat_id\":1,\"marker_guid\":\"sent-1\",\"at\":1700000000000}]}"
            guard let partialData = oldPartial.data(using: .utf8) else { XCTFail("partial fixture encoding failed"); return }
            let partialState = try StateCoding.decoder().decode(PersistedState.self, from: partialData)
            let partialJSON = try StateCoding.encoder().encode(partialState)
            let partialObject = try JSONSerialization.jsonObject(with: partialJSON) as? [String: Any]
            let partialEntry = (partialObject?["partial_replies"] as? [[String: Any]])?.first
            XCTAssertEqual(partialEntry?["body_resends"] as? Int, 0)
            XCTAssertEqual(partialEntry?["marker_guid"] as? String, "sent-1")
            let h = splitHarness()
            h.state.state = state
            guard let e = await splitOpened(h) else { return }
            await e.pollReplies()
            XCTAssertTrue(h.sender.sent.isEmpty)
            XCTAssertTrue(h.state.deadLetters.contains { $0.error == "send_interrupted" })
        } catch { XCTFail("legacy state decode failed: \(error)") }
    }

    func testReentrantCallsDoNotDuplicateEitherPart() async {
        let h = splitHarness()
        h.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 7, text: B, guid: "origin")], nextCursor: nil),
            ReplyPage(replies: [], nextCursor: nil),
            ReplyPage(replies: [routedReply("r1", chat: 7, text: B, guid: "origin")], nextCursor: nil),
        ]
        guard let e = await splitOpened(h) else { return }
        var inFlightDuringBodySend: Int?
        h.sender.onSend = {
            if h.sender.sent.count == 2 { inFlightDuringBodySend = await e.inFlightReplyCount() }
            await e.pollReplies()
            await e.resumeRateLimit(chatID: 7)
        }
        await e.pollReplies()
        XCTAssertEqual(inFlightDuringBodySend, 1)
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B])
    }

    func testSameChatRepliesDoNotInterleave() async {
        let h = Harness()
        h.allow.ids = [7]
        h.config.replyFetchURL = "https://example.com/replies"
        seedRoute(h, guid: "origin-a", chat: 7)
        seedRoute(h, guid: "origin-b", chat: 7)
        h.replies.pages = [
            ReplyPage(replies: [routedReply("r1", chat: 7, text: "a", guid: "origin-a"), routedReply("r2", chat: 7, text: "b", guid: "origin-b")], nextCursor: nil),
            ReplyPage(replies: [routedReply("r2", chat: 7, text: "b", guid: "origin-b")], nextCursor: nil),
        ]
        h.sender.script = [
            .success(SendReceipt(id: 1, guid: "m1", status: "sent")), .failure(.notStarted),
            .success(SendReceipt(id: 3, guid: "m1-again", status: "sent")), .success(SendReceipt(id: 4, guid: "a", status: "sent")),
            .success(SendReceipt(id: 5, guid: "m2", status: "sent")), .success(SendReceipt(id: 6, guid: "b", status: "sent")),
        ]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, "a"])
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, "a", "a", M, "b"])

        let restarted = Harness()
        restarted.allow.ids = [7]
        restarted.config.replyFetchURL = "https://example.com/replies"
        seedRoute(restarted, guid: "origin-a", chat: 7)
        seedRoute(restarted, guid: "origin-b", chat: 7)
        guard splitInstallPartials(restarted, [splitPartial("r1")]) else { return }
        restarted.replies.pages = [
            ReplyPage(replies: [routedReply("r2", chat: 7, text: "b", guid: "origin-b"), routedReply("r1", chat: 7, text: "a", guid: "origin-a")], nextCursor: nil),
            ReplyPage(replies: [routedReply("r2", chat: 7, text: "b", guid: "origin-b")], nextCursor: nil),
        ]
        guard let next = await splitOpened(restarted) else { return }
        await next.pollReplies()
        XCTAssertEqual(restarted.sender.sent.map(\.text), ["a"])
        restarted.clock.current = restarted.clock.current.addingTimeInterval(15)
        await next.pollReplies()
        XCTAssertEqual(restarted.sender.sent.map(\.text), ["a", M, "b"])
    }

    func testBodyStartingWithLampIsNotSent() async {
        let invalid = [M + " 🪔 hi", "🪔 🪔 hi", M + " \u{200B}🪔 hi", M + " 🪔\u{FE0F}hi"]
        for (i, text) in invalid.enumerated() {
            let id = "r\(i)"
            let h = splitHarness(text, id: id)
            guard let e = await splitOpened(h) else { return }
            await e.pollReplies()
            XCTAssertTrue(h.sender.sent.isEmpty)
            XCTAssertTrue(h.state.state.handledReplyIDs.contains(id))
            let snapshot = await e.snapshot()
            XCTAssertEqual(snapshot.lastError, "reply_still_matches_signal")
        }
        let h = splitHarness("🪔 answer")
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, "answer"])
    }

    func testEmptyBodySendsNothing() async {
        for (index, text) in ["", M, M + "　\n"].enumerated() {
            let raw: [String: Any] = ["replies": [["id": "r\(index)", "chat_id": 7, "in_reply_to_guid": "origin", "text": text, "created_at": "2023-11-14T22:13:20Z"]]]
            do {
                let data = try JSONSerialization.data(withJSONObject: raw)
                let page = try ReplyPageDecoder.decode(data)
                let h = splitHarness(text, id: "r\(index)")
                h.replies.pages = [page]
                guard let e = await splitOpened(h) else { return }
                await e.pollReplies()
                XCTAssertTrue(h.sender.sent.isEmpty)
                XCTAssertTrue(h.log.records.contains { $0.code == "reply_empty_body" })
                let snapshot = await e.snapshot()
                XCTAssertNil(snapshot.lastError)
                XCTAssertTrue(h.state.deadLetters.isEmpty)
                XCTAssertTrue(h.state.state.handledReplyIDs.contains("r\(index)"))
            } catch { XCTFail("reply fixture decode failed: \(error)") }
        }
    }

    func testEchoesAreIgnoredInsideTheWindowOnly() async {
        let h = splitHarness()
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 2)
        let sent = await e.ingestWatchLine(watchLine(id: 101, guid: "sent-1", chat: 7, fromMe: true, text: M, created: "2023-11-14T22:13:20Z"))
        let within = await e.ingestWatchLine(watchLine(id: 102, guid: "echo-b", chat: 7, fromMe: true, text: M, created: "2023-11-14T22:13:20Z"))
        let edge = await e.ingestWatchLine(watchLine(id: 103, guid: "echo-c", chat: 7, fromMe: true, text: M, created: "2023-11-14T22:15:20Z"))
        let after = await e.ingestWatchLine(watchLine(id: 104, guid: "echo-d", chat: 7, fromMe: true, text: M, created: "2023-11-14T22:15:21Z"))
        let body = await e.ingestWatchLine(watchLine(id: 105, guid: "echo-e", chat: 7, fromMe: true, text: B, created: "2023-11-14T22:14:20Z"))
        let before = await e.ingestWatchLine(watchLine(id: 106, guid: "echo-f", chat: 7, fromMe: true, text: B, created: "2023-11-14T22:11:19Z"))
        let duplicate = await e.ingestWatchLine(watchLine(id: 107, guid: "echo-b", chat: 7, fromMe: true, text: M, created: "2023-11-14T22:13:20Z"))
        XCTAssertEqual(sent, .ignoredSentGUID)
        XCTAssertEqual(within, .ignoredFingerprint)
        XCTAssertEqual(edge, .ignoredFingerprint)
        XCTAssertEqual(after, .ignoredReplyMarker)
        XCTAssertEqual(body, .ignoredFingerprint)
        XCTAssertEqual(before, .ignoredNoSignal)
        XCTAssertEqual(duplicate, .duplicate)
        XCTAssertTrue(h.webhook.bodies.isEmpty)
        let signal = await e.ingestWatchLine(watchLine(id: 108, guid: "echo-h", chat: 7, fromMe: true, text: "🪔 hi", created: "2023-11-14T22:13:20Z"))
        XCTAssertEqual(signal, .delivered)
        XCTAssertEqual(h.webhook.bodies.count, 1)
    }

    func testRollbackRemovesOneFingerprint() async {
        let h = Harness()
        h.allow.ids = [7, 8]
        h.config.replyFetchURL = "https://example.com/replies"
        seedRoute(h, guid: "origin-a", chat: 7)
        seedRoute(h, guid: "origin-b", chat: 8)
        h.replies.pages = [ReplyPage(replies: [routedReply("r1", chat: 7, text: "same", guid: "origin-a"), routedReply("r2", chat: 8, text: "same", guid: "origin-b")], nextCursor: nil)]
        h.sender.script = [.success(SendReceipt(id: 1, guid: "one", status: "sent")), .success(SendReceipt(id: 2, guid: "two", status: "sent")), .failure(.notStarted)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        let markerHash = SHA256.hex(Data(M.utf8))
        XCTAssertEqual(h.state.state.fingerprints.filter { $0.hash == markerHash && $0.sentAt == h.clock.current }.count, 1)
    }

    func testMarkerSettingDoesNotChangeTheFirstMessage() async {
        for marker in ["🤖", " 🤖 \n", "🪔", ""] {
            let h = splitHarness("🤖 hi")
            h.config.marker = marker
            guard let e = await splitOpened(h) else { return }
            await e.pollReplies()
            guard h.sender.sent.count >= 1 else { XCTFail("marker send missing"); return }
            XCTAssertEqual(h.sender.sent[0].text.unicodeScalars.map(\.value), [0x1F9DE, 0x200D, 0x2642, 0xFE0F])
            XCTAssertEqual(h.sender.sent.map(\.text), [M, "🤖 hi"])
            XCTAssertFalse(h.log.records.contains { $0.code == "marker_replaced" })
        }
        let json = "{\"marker\":\"🤖\"}"
        do { _ = try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8)) }
        catch { XCTFail("legacy marker config failed to decode: \(error)") }
    }

    func testLogsAndDeadLettersHaveNoBody() async {
        let scenarios: [(String, [Result<SendReceipt, SendFailure>], Bool)] = [
            ("normal", [], false),
            ("failed resend", [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.failed), .success(SendReceipt(id: 3, guid: "body", status: "sent"))], false),
            ("uncertain resend", [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.uncertain), .failure(.uncertain)], false),
            ("marker hold", [.failure(.notStarted)], false),
            ("body hold", [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.notStarted)], false),
            ("body locked", [.success(SendReceipt(id: 1, guid: "marker", status: "sent"))], true),
        ]
        for (name, script, lockBeforeBody) in scenarios {
            let h = splitHarness("BODY-SENTINEL-こんにちは")
            h.sender.script = script
            guard let e = await splitOpened(h) else { return }
            if lockBeforeBody {
                h.sender.onSend = { if h.sender.sent.count == 1 { h.lock.locked = true } }
            }
            await e.pollReplies()
            _ = name
            let sentRecords = h.log.records.filter { $0.code == "reply_sent" }
            XCTAssertTrue(sentRecords.allSatisfy { ["marker", "body", "resend"].contains($0.detail ?? "") })
            if name == "normal" { XCTAssertEqual(sentRecords.map { $0.detail ?? "" }, ["marker", "body"]) }
            assertNoBody(h, "BODY-SENTINEL-こんにちは")
        }
        let interrupted = splitHarness("BODY-SENTINEL-こんにちは")
        let pending: [[String: Any]] = [["reply_id": "r1", "chat_id": 7, "hash": "abc", "at": 1_700_000_000_000, "rate_counted": true, "part": "body"]]
        guard splitInstallPartials(interrupted, [splitPartial("r1")], pending: pending), let e = await splitOpened(interrupted) else { return }
        await e.pollReplies()
        assertNoBody(interrupted, "BODY-SENTINEL-こんにちは")
    }

    func testExpiredBodyHoldIsDropped() async {
        let h = splitHarness()
        h.config.routeTTLSeconds = 60
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.notStarted)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        h.clock.current = h.clock.current.addingTimeInterval(61)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B])
        XCTAssertTrue(h.log.records.contains { $0.code == "reply_too_old" })
        XCTAssertFalse((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).contains { $0["reply_id"] as? String == "r1" })
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
    }

    func testDatabaseResetClearsPartials() async {
        let h = splitHarness()
        guard splitInstallPartials(h, [splitPartial("r1")]), let e = await splitOpened(h) else { return }
        XCTAssertEqual((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]])?.count, 1)
        await e.showChats([ChatSummary(id: 7, title: "room", isGroup: false, guid: "new-db")])
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testDatabaseResetDuringTheMarkerSendDropsTheResult() async {
        for notStarted in [false, true] {
            let h = splitHarness()
            if notStarted { h.sender.script = [.failure(.notStarted)] }
            guard let e = await splitOpened(h) else { return }
            h.sender.onSend = {
                if h.sender.sent.count == 1 {
                    _ = await e.ingestWatchLine(watchLine(id: 50, guid: "swap", chat: 7, fromMe: true, text: "x", chatGUID: "new-7"))
                    await e.setChatEnabled(7, guid: "new-7", enabled: true)
                    await e.showChats([ChatSummary(id: 7, title: "room", isGroup: false, guid: "new-7")])
                }
            }
            await e.pollReplies()
            XCTAssertEqual(h.sender.sent.map(\.text), [M])
            XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
            let snapshot = await e.snapshot()
            XCTAssertEqual(snapshot.heldCount, 0)
            if !notStarted {
                XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
                XCTAssertTrue(h.state.state.sentGUIDs.contains("sent-1"))
                XCTAssertTrue(h.log.records.contains { $0.code == "reply_dropped_db_reset" && $0.detail == "marker" })
            }
            h.clock.current = h.clock.current.addingTimeInterval(15)
            await e.retryHolds()
            XCTAssertEqual(h.sender.sent.count, 1)
        }
    }

    func testDatabaseResetDuringTheBodySendDoesNotResend() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.failed)]
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = {
            if h.sender.sent.count == 2 {
                _ = await e.ingestWatchLine(watchLine(id: 50, guid: "swap", chat: 7, fromMe: true, text: "x", chatGUID: "new-7"))
                await e.setChatEnabled(7, guid: "new-7", enabled: true)
                await e.showChats([ChatSummary(id: 7, title: "room", isGroup: false, guid: "new-7")])
            }
        }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 2)
        XCTAssertTrue(h.state.deadLetters.isEmpty)
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue(h.log.records.contains { $0.code == "reply_dropped_db_reset" && $0.detail == "body" })
    }
}

