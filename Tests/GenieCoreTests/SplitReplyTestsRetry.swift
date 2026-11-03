import Foundation
import XCTest
@testable import GenieCore

extension SplitReplyTests {
    func testBodyFailedIsResentOnce() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.failed), .success(SendReceipt(id: 3, guid: "body-again", status: "sent"))]
        var sawSavedResend = false
        h.sender.onSend = {
            if h.sender.sent.count == 3, let json = self.splitJSON(h.state.state) {
                let partial = (json["partial_replies"] as? [[String: Any]] ?? []).first
                let pending = json["pending_sends"] as? [[String: Any]] ?? []
                sawSavedResend = partial?["body_resends"] as? Int == 1 && pending.contains { $0["part"] as? String == "body" }
            }
        }
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B])
        XCTAssertTrue(sawSavedResend)
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue(h.state.deadLetters.isEmpty)
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 1)
    }

    func testMarkerIsNeverResentWhileTheBodyIsRetried() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.failed), .failure(.notStarted), .success(SendReceipt(id: 4, guid: "body-final", status: "sent"))]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B, B])
        XCTAssertEqual(h.sender.sent.map(\.text).filter { $0 == M }.count, 1)

        let failed = splitHarness()
        failed.state.shouldFailDeadLetter = true
        failed.sender.script = [.failure(.failed)]
        guard let failedEngine = await splitOpened(failed) else { return }
        await failedEngine.pollReplies()
        let failedSnapshot = await failedEngine.snapshot()
        XCTAssertEqual(failedSnapshot.heldLockCount, 1)
        failed.clock.current = failed.clock.current.addingTimeInterval(15)
        await failedEngine.retryHolds()
        XCTAssertEqual(failed.sender.sent.map(\.text), [M, M, B])

        let uncertain = splitHarness()
        uncertain.state.shouldFailDeadLetter = true
        uncertain.sender.script = [.failure(.uncertain)]
        guard let uncertainEngine = await splitOpened(uncertain) else { return }
        await uncertainEngine.pollReplies()
        uncertain.clock.current = uncertain.clock.current.addingTimeInterval(15)
        await uncertainEngine.retryHolds()
        await uncertainEngine.pollReplies()
        XCTAssertEqual(uncertain.sender.sent.map(\.text), [M])
        let uncertainSnapshot = await uncertainEngine.snapshot()
        XCTAssertEqual(uncertainSnapshot.heldLockCount, 0)
        XCTAssertEqual(uncertainSnapshot.lastError, "deadletter_write_failed")
        do {
            let (state, _) = try reloaded(uncertain.state.state)
            let restarted = Harness()
            restarted.allow.ids = [7]
            restarted.config.replyFetchURL = "https://example.com/replies"
            restarted.state.state = state
            guard let next = await splitOpened(restarted) else { return }
            await next.pollReplies()
            XCTAssertTrue(restarted.sender.sent.isEmpty)
            XCTAssertTrue(restarted.state.deadLetters.contains { $0.error == "send_interrupted" })
        } catch { XCTFail("state reload failed: \(error)") }
    }

    func testBodyUncertainIsResentOnce() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.uncertain), .success(SendReceipt(id: 3, guid: "body-again", status: "sent"))]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B])
        XCTAssertTrue(h.state.deadLetters.isEmpty)
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 1)
        XCTAssertEqual(h.state.state.fingerprints.filter { $0.hash == SHA256.hex(Data(B.utf8)) }.count, 2)
    }

    func testUncertainResendGoesToDeadLetter() async {
        let failurePairs: [(SendFailure, SendFailure)] = [(.uncertain, .uncertain), (.failed, .uncertain)]
        for failures in failurePairs {
            let h = splitHarness()
            h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(failures.0), .failure(failures.1)]
            guard let e = await splitOpened(h) else { return }
            await e.pollReplies()
            h.clock.current = h.clock.current.addingTimeInterval(15)
            await e.retryHolds()
            XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B])
            XCTAssertTrue(h.state.deadLetters.contains { $0.error == "body_send_failed" || $0.error == "body_send_uncertain" })
            XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        }
    }

    func testCrashDuringTheResendIsDeadLettered() async {
        let h = splitHarness()
        let pending: [[String: Any]] = [["reply_id": "r1", "chat_id": 7, "hash": "abc", "at": 1_700_000_000_000, "rate_counted": true, "part": "body"]]
        guard splitInstallPartials(h, [splitPartial("r1", resends: 1)], pending: pending), let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertTrue(h.state.deadLetters.contains { $0.error == "body_send_interrupted" })
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
        h.replies.pages = [ReplyPage(replies: [routedReply("r1", chat: 7, text: B, guid: "origin")], nextCursor: nil)]
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [B])
    }

    func testCrashDuringTheFirstBodyUsesTheOneResend() async {
        let pending: [[String: Any]] = [["reply_id": "r1", "chat_id": 7, "hash": "abc", "at": 1_700_000_000_000, "rate_counted": true, "part": "body"]]
        let h = splitHarness()
        guard splitInstallPartials(h, [splitPartial("r1", resends: 0)], pending: pending), let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [B])
        XCTAssertTrue(h.state.deadLetters.isEmpty)
        XCTAssertEqual((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).first?["body_resends"] as? Int, 1)
        XCTAssertTrue((splitJSON(h.state.state)?["pending_sends"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue(h.log.records.contains { $0.code == "send_interrupted" && $0.detail == "body" })

        let failed = splitHarness()
        failed.sender.script = [.failure(.failed)]
        guard splitInstallPartials(failed, [splitPartial("r1", resends: 0)], pending: pending), let failedEngine = await splitOpened(failed) else { return }
        await failedEngine.pollReplies()
        XCTAssertEqual(failed.sender.sent.map(\.text), [B])
        XCTAssertTrue(failed.state.deadLetters.contains { $0.error == "body_send_failed" })
    }

    func testRestartBeforeTheResendSendsItOnce() async {
        let h = splitHarness()
        guard splitInstallPartials(h, [splitPartial("r1", resends: 1)]) else { return }
        do {
            let (state, json) = try reloaded(h.state.state)
            XCTAssertTrue(json.contains("\"body_resends\":1"))
            XCTAssertTrue(json.contains("\"partial_replies\""))
            let restarted = Harness()
            restarted.allow.ids = [7]
            restarted.config.replyFetchURL = "https://example.com/replies"
            restarted.state.state = state
            restarted.replies.pages = [ReplyPage(replies: [routedReply("r1", chat: 7, text: B, guid: "origin")], nextCursor: nil)]
            guard let e = await splitOpened(restarted) else { return }
            await e.pollReplies()
            XCTAssertEqual(restarted.sender.sent.map(\.text), [B])
            XCTAssertTrue(restarted.state.deadLetters.isEmpty)
            XCTAssertEqual((splitJSON(restarted.state.state)?["partial_replies"] as? [[String: Any]] ?? []).first?["body_resends"] as? Int, 1)

            let failed = Harness()
            failed.allow.ids = [7]
            failed.config.replyFetchURL = "https://example.com/replies"
            failed.state.state = state
            failed.sender.script = [.failure(.failed)]
            guard let failedEngine = await splitOpened(failed) else { return }
            await failedEngine.pollReplies()
            XCTAssertEqual(failed.sender.sent.map(\.text), [B])
            XCTAssertTrue(failed.state.deadLetters.contains { $0.error == "body_send_failed" })
        } catch { XCTFail("state reload failed: \(error)") }
    }

    func testResendIgnoresTheRateLimitAndUsesNoQuota() async {
        let h = splitHarness()
        h.state.state.haltedChatIDs = [7]
        h.state.state.rateEvents = (0..<5).map { _ in RateEvent(chatID: 7, at: h.clock.current) }
        let pending: [[String: Any]] = [["reply_id": "r1", "chat_id": 7, "hash": "abc", "at": 1_700_000_000_000, "rate_counted": true, "part": "body"]]
        h.sender.script = [.failure(.failed), .success(SendReceipt(id: 2, guid: "sent-again", status: "sent"))]
        guard splitInstallPartials(h, [splitPartial("r1")], pending: pending), let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [B, B])
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 5)
        XCTAssertEqual(h.state.state.haltedChatIDs, [7])
    }

    func testPauseBeforeTheResendKeepsTheCount() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.uncertain), .failure(.failed)]
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = { if h.sender.sent.count == 3 { await e.setPaused(true) } }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 3)
        XCTAssertEqual((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).first?["body_resends"] as? Int, 1)
        let paused = await e.snapshot()
        XCTAssertEqual(paused.heldCount, 1)
        await e.setPaused(false)
        h.sender.onSend = nil
        h.sender.script = [.failure(.failed)]
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.count, 4)
        XCTAssertTrue(h.state.deadLetters.contains { $0.error == "body_send_failed" })
        await e.retryHolds()
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 4)
    }

    func testFinalBodyFailureWithoutDeadLetterIsNotResent() async {
        let h = splitHarness()
        h.state.shouldFailDeadLetter = true
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.failed), .failure(.failed)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        await e.retryHolds()
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B])
        XCTAssertTrue(h.state.deadLetters.isEmpty)
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue((splitJSON(h.state.state)?["pending_sends"] as? [[String: Any]] ?? []).contains { $0["part"] as? String == "body" && $0["rate_counted"] as? Bool == true })
        let snapshot = await e.snapshot()
        XCTAssertEqual(snapshot.lastError, "deadletter_write_failed")
        h.state.shouldFailDeadLetter = false
        do {
            let (state, _) = try reloaded(h.state.state)
            let restarted = Harness()
            restarted.allow.ids = [7]
            restarted.config.replyFetchURL = "https://example.com/replies"
            restarted.state.state = state
            guard let next = await splitOpened(restarted) else { return }
            await next.pollReplies()
            XCTAssertTrue(restarted.state.deadLetters.contains { $0.error == "body_send_interrupted" })
            XCTAssertTrue(restarted.sender.sent.isEmpty)
        } catch { XCTFail("state reload failed: \(error)") }
    }

    func testFinalBodyUncertainWithoutDeadLetterIsRecordedNextStart() async {
        let h = splitHarness()
        h.state.shouldFailDeadLetter = true
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.uncertain), .failure(.uncertain)]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B, B])
        XCTAssertTrue(h.state.deadLetters.isEmpty)
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue((splitJSON(h.state.state)?["pending_sends"] as? [[String: Any]] ?? []).contains { $0["part"] as? String == "body" && $0["rate_counted"] as? Bool == true })
        h.state.shouldFailDeadLetter = false
        do {
            let (state, _) = try reloaded(h.state.state)
            let restarted = Harness()
            restarted.allow.ids = [7]
            restarted.config.replyFetchURL = "https://example.com/replies"
            restarted.state.state = state
            guard let next = await splitOpened(restarted) else { return }
            await next.pollReplies()
            XCTAssertTrue(restarted.state.deadLetters.contains { $0.error == "body_send_interrupted" })
            XCTAssertTrue(restarted.sender.sent.isEmpty)
        } catch { XCTFail("state reload failed: \(error)") }
    }

    func testInterruptedBodyWithoutDeadLetterIsRecordedNextStart() async {
        let h = splitHarness()
        h.state.shouldFailDeadLetter = true
        let pending: [[String: Any]] = [["reply_id": "r1", "chat_id": 7, "hash": "abc", "at": 1_700_000_000_000, "rate_counted": true, "part": "body"]]
        guard splitInstallPartials(h, [splitPartial("r1", resends: 1)], pending: pending), let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue((splitJSON(h.state.state)?["pending_sends"] as? [[String: Any]] ?? []).contains { $0["part"] as? String == "body" && $0["rate_counted"] as? Bool == true })
        XCTAssertTrue(h.log.records.contains { $0.code == "deadletter_write_failed" })
        do {
            let (state, _) = try reloaded(h.state.state)
            let restarted = Harness()
            restarted.allow.ids = [7]
            restarted.config.replyFetchURL = "https://example.com/replies"
            restarted.state.state = state
            guard let next = await splitOpened(restarted) else { return }
            await next.pollReplies()
            XCTAssertTrue(restarted.state.deadLetters.contains { $0.error == "body_send_interrupted" })
            XCTAssertTrue(restarted.sender.sent.isEmpty)
        } catch { XCTFail("state reload failed: \(error)") }
    }

    func testNewStateRoundTripsThroughJSON() async {
        let h = splitHarness()
        let pending: [[String: Any]] = [["reply_id": "r1", "chat_id": 7, "hash": "abc", "at": 1_700_000_000_000, "rate_counted": true, "part": "body"]]
        guard splitInstallPartials(h, [splitPartial("r1", resends: 1)], pending: pending) else { return }
        do {
            let expected = h.state.state
            let (state, json) = try reloaded(expected)
            XCTAssertTrue(json.contains("\"partial_replies\""))
            XCTAssertTrue(json.contains("\"marker_guid\":\"sent-1\""))
            XCTAssertTrue(json.contains("\"body_resends\":1"))
            XCTAssertTrue(json.contains("\"part\":\"body\""))
            XCTAssertEqual(state, expected)
        } catch { XCTFail("state reload failed: \(error)") }
    }

    func testPartialSaveFailureHoldsTheBody() async {
        let h = splitHarness()
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = { if h.sender.sent.count == 1 { h.state.shouldFailSave = true } }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        let failedSnapshot = await e.snapshot()
        XCTAssertEqual(failedSnapshot.heldCount, 1)
        XCTAssertEqual(failedSnapshot.lastError, "state_save_failed")
        let diskState: PersistedState
        do {
            let (state, json) = try reloaded(h.state.state)
            diskState = state
            let pending = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["pending_sends"] as? [[String: Any]] ?? []
            XCTAssertTrue(pending.contains { $0["reply_id"] as? String == "r1" && $0["part"] as? String == "marker" })
        } catch { XCTFail("state reload failed: \(error)"); return }
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M])
        h.state.shouldFailSave = false
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B])
        XCTAssertEqual(h.sender.sent.map(\.text).filter { $0 == M }.count, 1)
        let restarted = Harness()
        restarted.allow.ids = [7]
        restarted.config.replyFetchURL = "https://example.com/replies"
        restarted.state.state = diskState
        guard let next = await splitOpened(restarted) else { return }
        await next.pollReplies()
        XCTAssertTrue(restarted.state.deadLetters.contains { $0.error == "send_interrupted" })
        XCTAssertTrue(restarted.sender.sent.isEmpty)
    }



    func testPartialDroppedByTheCapIsHandled() async {
        let h = splitHarness()
        let partials = (0..<5000).map { index -> [String: Any] in
            let id = String(format: "p%04d", index)
            seedRoute(h, guid: "route-\(id)", chat: 8)
            return splitPartial(id, chat: 8, markerGUID: "sent-\(index)")
        }
        guard splitInstallPartials(h, partials), let e = await splitOpened(h) else { return }
        var sawS2 = false
        h.sender.onSend = {
            if h.sender.sent.count == 2, let json = self.splitJSON(h.state.state) {
                let values = json["partial_replies"] as? [[String: Any]] ?? []
                sawS2 = values.count == 5000 && !values.contains { $0["reply_id"] as? String == "p0000" }
            }
        }
        await e.pollReplies()
        let values = splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []
        XCTAssertTrue(sawS2)
        XCTAssertEqual(values.count, 4999)
        XCTAssertFalse(values.contains { $0["reply_id"] as? String == "p0000" })
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("p0000"))
        XCTAssertEqual(h.log.records.filter { $0.code == "reply_partial_dropped" }.count, 1)
        XCTAssertEqual(h.sender.sent.map(\.text), [M, B])
        h.replies.pages = [ReplyPage(replies: [routedReply("p0000", chat: 8, text: B, guid: "route-p0000")], nextCursor: nil)]
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 2)
        do {
            let (state, _) = try reloaded(h.state.state)
            let next = Harness()
            next.allow.ids = [7, 8]
            next.config.replyFetchURL = "https://example.com/replies"
            next.state.state = state
            next.replies.pages = [ReplyPage(replies: [routedReply("p0000", chat: 8, text: B, guid: "route-p0000")], nextCursor: nil)]
            guard let restarted = await splitOpened(next) else { return }
            await restarted.pollReplies()
            XCTAssertTrue(next.sender.sent.isEmpty)
        } catch { XCTFail("state reload failed: \(error)") }

        let expired = splitHarness()
        expired.config.routeTTLSeconds = 60
        guard splitInstallPartials(expired, [splitPartial("old", at: 1_699_999_938_999)]), let expiredEngine = await splitOpened(expired) else { return }
        await expiredEngine.pollReplies()
        XCTAssertTrue(expired.state.state.handledReplyIDs.contains("old"))
        XCTAssertFalse((splitJSON(expired.state.state)?["partial_replies"] as? [[String: Any]] ?? []).contains { $0["reply_id"] as? String == "old" })
    }

    func testResendCountSaveFailureHoldsTheResend() async {
        let h = splitHarness()
        h.sender.script = [.success(SendReceipt(id: 1, guid: "marker", status: "sent")), .failure(.failed)]
        guard let e = await splitOpened(h) else { return }
        h.sender.onSend = { if h.sender.sent.count == 2 { h.state.shouldFailSave = true } }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 2)
        let blockedSnapshot = await e.snapshot()
        XCTAssertEqual(blockedSnapshot.heldCount, 1)
        XCTAssertEqual(blockedSnapshot.lastError, "state_save_failed")
        let diskState: PersistedState
        do {
            let (state, json) = try reloaded(h.state.state)
            diskState = state
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            let partial = (object?["partial_replies"] as? [[String: Any]])?.first
            let pending = object?["pending_sends"] as? [[String: Any]] ?? []
            XCTAssertEqual(partial?["body_resends"] as? Int, 0)
            XCTAssertTrue(pending.contains { $0["part"] as? String == "body" })
        } catch { XCTFail("state reload failed: \(error)"); return }
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.count, 2)
        h.state.shouldFailSave = false
        h.sender.onSend = nil
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await e.retryHolds()
        XCTAssertEqual(h.sender.sent.count, 3)
        XCTAssertEqual((splitJSON(h.state.state)?["partial_replies"] as? [[String: Any]] ?? []).first?["body_resends"] as? Int, 1)
        await e.retryHolds()
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 3)

        let disk = Harness()
        disk.allow.ids = [7]
        disk.config.replyFetchURL = "https://example.com/replies"
        disk.state.state = diskState
        guard let restarted = await splitOpened(disk) else { return }
        await restarted.pollReplies()
        XCTAssertEqual(disk.sender.sent.map(\.text), [B])
        XCTAssertEqual((splitJSON(disk.state.state)?["partial_replies"] as? [[String: Any]] ?? []).first?["body_resends"] as? Int, 1)
    }
}
