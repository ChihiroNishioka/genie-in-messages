import Foundation
import XCTest
@testable import GenieCore

final class ScriptedOutbound: OutboundSource, @unchecked Sendable {
    var entries: [FetchedOutbound] = []
    var fetchCount = 0
    func prepared(for config: GenieConfig) -> any OutboundSource { self }
    func fetch(cursor: String?, skipping: Set<String>, holding: Set<String>) async throws -> OutboundPage {
        fetchCount += 1
        return OutboundPage(entries: entries, nextCursor: cursor)
    }
}

final class OutboundHarness {
    static let family = "iMessage;+;chat000000000000000001"
    static let owner = "iMessage;-;owner@example.com"
    let h = Harness()
    let source = ScriptedOutbound()
    let provider: MutableConfig
    init() {
        var config = GenieConfig.productDefaults
        config.outboundNotionDataSourceID = "11111111-1111-4111-8111-111111111111"
        config.outboundTargets = ["family": Self.family, "self": Self.owner]
        config.groupChatGUIDs = [Self.family]
        config.selfChatIDs = [8]
        provider = MutableConfig(config)
        h.allow.ids = [8]
        h.allow.guids = [8: Self.owner]
    }
    func row(_ page: String = "page-0000", key: String = "key-0000", target: OutboundTarget = .family, text: String = "お知らせ") -> FetchedOutbound {
        FetchedOutbound(pageID: page, idempotencyKey: key, target: target, text: text,
                        createdAt: ISO8601.string(from: h.clock.now()), invalidCode: nil)
    }
    var chats: [ChatSummary] {
        [ChatSummary(id: 7, title: "family", isGroup: true, guid: Self.family),
         ChatSummary(id: 8, title: "self", isGroup: false, guid: Self.owner)]
    }
    func engine(stop: StopSignal? = nil) throws -> GenieEngine {
        try GenieEngine(configProvider: provider, initialConfig: provider.config, stateStore: h.store ?? h.state,
            allowlistStore: h.allow, replySource: h.replies, outboundSource: source, sender: h.sender,
            markerImage: h.markerImage, webhook: h.webhook, secrets: h.secrets, lock: h.lock,
            clock: h.clock, log: h.log, stop: stop ?? h.stop)
    }
    func opened() async throws -> GenieEngine {
        let engine = try engine()
        await engine.showChats(chats)
        return engine
    }
}

final class OutboundSendTests: XCTestCase {
    func testOB03FamilySendsWithoutRoute() async throws {
        let f = OutboundHarness()
        f.source.entries = [f.row()]
        let e = try await f.opened()
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ")])
        XCTAssertTrue(f.h.state.state.routes.isEmpty)
    }

    func testOB18UncertainBodyIsNeverRetried() async throws {
        let f = OutboundHarness()
        f.source.entries = [f.row()]
        f.h.sender.script = [.success(SendReceipt(id: 1, guid: "sent-0000", status: "sent")), .failure(.uncertain)]
        let e = try await f.opened()
        _ = await e.pollOutbound()
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertEqual(f.h.state.deadLetters.last?.error, "outbound_body_send_uncertain")
        XCTAssertTrue(f.h.state.state.pendingSends.isEmpty)
        XCTAssertTrue(f.h.state.state.partialReplies.isEmpty)
    }

    func testOB18ParserFailuresNeverRetryOutboundButReplyStillResends() async throws {
        let parsedFailure = SendResultParser.parse(stdout: "nope", stderr: "", exitCode: 1)
        let emptyOutput = SendResultParser.parse(stdout: "", stderr: "", exitCode: 1)
        let malformed = SendResultParser.parse(stdout: "{", stderr: "", exitCode: 1)
        for result in [parsedFailure, emptyOutput, malformed] {
            let f = OutboundHarness(); f.source.entries = [f.row()]
            f.h.sender.script = [.success(SendReceipt(id: 1, guid: "marker-0000", status: "sent")), result]
            let e = try await f.opened(); _ = await e.pollOutbound(); _ = await e.pollOutbound()
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ")])
            XCTAssertEqual(f.h.state.deadLetters.last?.error, "outbound_body_send_failed")
        }

        let reply = OutboundHarness()
        reply.provider.config.replyFetchURL = "https://example.com/replies"
        seedRoute(reply.h, guid: "origin-0000", chat: 7)
        reply.h.replies.pages = [ReplyPage(replies: [routedReply("reply-0000", chat: 7, text: "返事", guid: "origin-0000")], nextCursor: nil)]
        reply.h.sender.script = [
            .success(SendReceipt(id: 1, guid: "marker-0000", status: "sent")),
            parsedFailure,
            .success(SendReceipt(id: 2, guid: "body-0000", status: "sent")),
        ]
        let replyEngine = try await reply.opened(); _ = await replyEngine.pollReplies()
        XCTAssertEqual(reply.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("返事"), .text("返事")])
    }

    func testOB24SameKeyDifferentPagesSendsOnce() async throws {
        let f = OutboundHarness()
        f.source.entries = [f.row(), f.row("page-0001")]
        let e = try await f.opened()
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "outbound_duplicate_key" })
    }




    func testOB19OutboundEchoesNeverPostWebhook() async throws {
        for fallback in [false, true] {
            let f = OutboundHarness()
            f.provider.config.webhookURL = "https://example.com/webhook"
            if fallback { f.h.markerImage = StaticMarkerImage(url: nil) }
            f.source.entries = [f.row()]
            let e = try await f.opened()
            _ = await e.pollOutbound()
            XCTAssertEqual(f.h.sender.outgoing.count, 2)
            let created = ISO8601.string(from: f.h.clock.now())
            for (index, output) in f.h.sender.outgoing.enumerated() {
                let text = outgoingText(output.item) ?? ""
                let echoed = await e.ingestWatchLine(watchLine(
                    id: 100 + index, guid: "sent-\(index + 1)", chat: 7, fromMe: true,
                    text: text, created: created, chatGUID: OutboundHarness.family, isGroup: true
                ))
                XCTAssertEqual(echoed, .ignoredSentGUID)
            }
            let bodyEcho = await e.ingestWatchLine(watchLine(
                id: 110, guid: "echo-body-0000", chat: 7, fromMe: true,
                text: "お知らせ", created: created, chatGUID: OutboundHarness.family, isGroup: true
            ))
            XCTAssertEqual(bodyEcho, .ignoredFingerprint)
            let markerEcho = await e.ingestWatchLine(watchLine(
                id: 111, guid: "echo-marker-0000", chat: 7, fromMe: true,
                text: f.provider.config.replyMarker, created: created,
                chatGUID: OutboundHarness.family, isGroup: true
            ))
            XCTAssertTrue(markerEcho == .ignoredFingerprint || markerEcho == .ignoredReplyMarker)
            XCTAssertTrue(f.h.webhook.bodies.isEmpty)
        }
    }
    func testOB21ReplyAndOutboundShareRateQuota() async throws {
        let f = OutboundHarness()
        f.provider.config.replyFetchURL = "https://example.com/replies"
        f.provider.config.rateLimitCount = 1
        seedRoute(f.h, guid: "origin-0000", chat: 7)
        f.h.replies.pages = [ReplyPage(replies: [routedReply("reply-0000", chat: 7, text: "返事", guid: "origin-0000")], nextCursor: nil)]
        f.source.entries = [f.row()]
        let e = try await f.opened()
        _ = await e.pollReplies()
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("返事")])
        XCTAssertEqual(f.h.state.state.rateEvents.count, 1)
        XCTAssertTrue(f.h.state.state.pendingSends.isEmpty)
        XCTAssertTrue(f.h.state.state.partialReplies.isEmpty)
    }
    func testOB21ReplyWaitsUntilOutboundBodyFinishes() async throws {
        let f = OutboundHarness()
        f.provider.config.replyFetchURL = "https://example.com/replies"
        seedRoute(f.h, guid: "origin-0000", chat: 7)
        let reply = ReplyPage(replies: [routedReply("reply-0000", chat: 7, text: "返事", guid: "origin-0000")], nextCursor: nil)
        f.h.replies.pages = [reply, reply]
        f.source.entries = [f.row()]
        let e = try await f.opened()
        let arrived = Gate()
        let release = Gate()
        f.h.sender.onSendFile = { arrived.open(); await release.wait() }
        let task = Task { await e.pollOutbound() }
        await arrived.wait()
        _ = await e.pollReplies()
        XCTAssertEqual(f.h.sender.outgoing.count, 1)
        f.h.sender.onSendFile = nil
        release.open()
        _ = await task.value
        _ = await e.pollReplies()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ"), .file(expectedGIFPath()), .text("返事")])
    }}
final class OutboundRecoveryTests: XCTestCase {
    func testOB14GIFDefinitiveFailureUsesCustomMarker() async throws {
        let f = OutboundHarness(); f.provider.config.replyMarker = "🕊️"
        f.source.entries = [f.row()]; f.h.sender.script = [.failure(.failed)]
        let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("🕊️"), .text("お知らせ")])
        let missing = OutboundHarness(); missing.h.markerImage = StaticMarkerImage(url: nil)
        missing.source.entries = [missing.row()]; let second = try await missing.opened(); _ = await second.pollOutbound()
        XCTAssertEqual(missing.h.sender.outgoing.map(\.item), [.text(ReplyComposer.markerText), .text("お知らせ")])
    }
    func testOB16UncertainAndEmptyGUIDMarkerAreTerminalAcrossRestart() async throws {
        for result: Result<SendReceipt, SendFailure> in [.failure(.uncertain), .success(SendReceipt(id: 1, guid: "", status: "sent"))] {
            let f = OutboundHarness(); f.source.entries = [f.row()]; f.h.sender.script = [result]
            let e = try await f.opened(); _ = await e.pollOutbound()
            let restarted = try await f.opened(); _ = await restarted.pollOutbound()
            XCTAssertEqual(f.h.sender.outgoing.count, 1); XCTAssertTrue(f.h.sender.sent.isEmpty)
        }
    }
    func testOB17NotStartedMarkerAndBodyHoldPreserveRetryBudget() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; f.h.sender.script = [.failure(.notStarted)]
        let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 1); XCTAssertTrue(f.h.sender.sent.isEmpty)
        f.h.clock.current.addTimeInterval(60); await e.retryHolds()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .file(expectedGIFPath()), .text("お知らせ")])
        let body = OutboundHarness(); body.source.entries = [body.row()]
        body.h.sender.script = [.success(SendReceipt(id: 1, guid: "marker-0000", status: "sent")), .failure(.notStarted), .success(SendReceipt(id: 2, guid: "body-0000", status: "sent"))]
        let second = try await body.opened(); _ = await second.pollOutbound()
        XCTAssertEqual(body.h.state.state.outbound.records.first?.stage.rawValue, "body_ready")
        XCTAssertTrue(body.h.state.state.partialReplies.isEmpty)
        XCTAssertTrue(body.h.state.state.pendingSends.isEmpty)
        body.h.clock.current.addTimeInterval(60); await second.retryHolds()
        XCTAssertEqual(body.h.sender.outgoing.count, 3)
        XCTAssertEqual(body.h.sender.sent.count, 2)
        XCTAssertEqual(body.h.state.state.rateEvents.count, 1)
    }
    func testOB18DefinitiveBodyFailureNeverRetries() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]
        f.h.sender.script = [.success(SendReceipt(id: 1, guid: "marker-0000", status: "sent")), .failure(.failed)]
        let e = try await f.opened(); _ = await e.pollOutbound(); _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ")])
        XCTAssertEqual(f.h.state.deadLetters.last?.error, "outbound_body_send_failed")
        XCTAssertTrue(f.h.state.state.pendingSends.isEmpty)
        XCTAssertTrue(f.h.state.state.partialReplies.isEmpty)
        XCTAssertEqual(f.h.state.state.rateEvents.count, 1)
    }
    func testOB29InterruptedBodyNeverRestarts() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]
        var durable: PersistedState?
        f.h.sender.onSend = { if f.h.sender.outgoing.count == 2 { durable = f.h.state.state; f.h.stop.stop() } }
        let e = try await f.opened(); _ = await e.pollOutbound()
        f.h.sender.onSend = nil; f.h.state.state = try XCTUnwrap(durable)
        let restarted = try f.engine(stop: StopSignal()); await restarted.showChats(f.chats); _ = await restarted.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertEqual(f.h.state.deadLetters.last?.error, "outbound_body_send_interrupted")
    }
    func testOB30BodySuccessThenTerminalSaveFailureNeverResends() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]
        f.h.sender.onSend = { if f.h.sender.outgoing.count == 2 { f.h.state.shouldFailSave = true } }
        let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertEqual(f.h.state.state.outbound.records.first?.stage.rawValue, "body_in_flight")
        XCTAssertTrue(f.h.state.state.pendingSends.isEmpty)
        f.h.state.shouldFailSave = false; f.h.sender.onSend = nil
        let restarted = try await f.opened(); _ = await restarted.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertEqual(f.h.state.deadLetters.last?.error, "outbound_body_send_interrupted")
    }
    func testOB30DeadLetterFailureDoesNotReopenSend() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; f.h.markerImage = StaticMarkerImage(url: nil)
        f.h.sender.script = [.failure(.failed)]; f.h.state.shouldFailDeadLetter = true
        let e = try await f.opened(); _ = await e.pollOutbound(); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.state.state.outbound.records.first?.deadLetterPending == true)
        let restarted = try await f.opened(); _ = await restarted.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 1)
        XCTAssertTrue(f.h.state.state.outbound.records.first?.deadLetterPending == true)
        f.h.state.shouldFailDeadLetter = false
        _ = try await f.opened()
        XCTAssertEqual(f.h.state.deadLetters.last?.kind, "outbound")
        XCTAssertFalse(f.h.state.state.outbound.records.first?.deadLetterPending ?? true)
    }




    func testOB20PauseAndStopAfterLockAwaitPreventFirstSend() async throws {
        for stopping in [false, true] {
            let f = OutboundHarness()
            f.source.entries = [f.row()]
            let e = try await f.opened()
            f.h.lock.onState = {
                if stopping { f.h.stop.stop() }
                else { await e.setPaused(true) }
            }
            _ = await e.pollOutbound()
            XCTAssertTrue(f.h.sender.outgoing.isEmpty)
            XCTAssertTrue(f.h.sender.sent.isEmpty)
            f.h.lock.onState = nil
            if !stopping {
                await e.setPaused(false)
                f.h.clock.current = f.h.clock.current.addingTimeInterval(20)
                await e.retryHolds()
                _ = await e.pollOutbound()
                XCTAssertEqual(f.h.sender.outgoing.count, 2)
            }
        }
    }
    func testOB20PauseAndStopBetweenPartsPreventBody() async throws {
        for stopping in [false, true] {
            let f = OutboundHarness()
            f.source.entries = [f.row()]
            let e = try await f.opened()
            f.h.sender.onSendFile = {
                if stopping { f.h.stop.stop() }
                else { await e.setPaused(true) }
            }
            _ = await e.pollOutbound()
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath())])
            XCTAssertTrue(f.h.sender.sent.isEmpty)
            f.h.sender.onSendFile = nil
            if !stopping {
                await e.setPaused(false)
                f.h.clock.current = f.h.clock.current.addingTimeInterval(20)
                await e.retryHolds()
                _ = await e.pollOutbound()
                XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ")])
            }
        }
    }
    func testOB20LockedHoldsAndUnknownLockAttemptsSend() async throws {
        for lock: ScreenLockState in [.locked, .unknown] {
            let f = OutboundHarness()
            f.h.lock.forced = lock
            f.source.entries = [f.row()]
            let e = try await f.opened()
            _ = await e.pollOutbound()
            if lock == .locked {
                XCTAssertTrue(f.h.sender.outgoing.isEmpty)
                XCTAssertTrue(f.h.sender.sent.isEmpty)
                f.h.lock.forced = .unlocked
                await e.refreshLock()
                f.h.clock.current = f.h.clock.current.addingTimeInterval(20)
                await e.retryHolds()
                _ = await e.pollOutbound()
            }
            XCTAssertEqual(f.h.sender.outgoing.count, 2)
        }
    }}
final class OutboundConfigurationChangeTests: XCTestCase {
    func testOB12GIFFailureRechecksConfigurationBeforeFallback() async throws {
        for change in ["off", "family", "source", "target"] {
            let f = OutboundHarness(); f.source.entries = [f.row()]
            f.h.sender.script = [.failure(.failed)]
            f.h.sender.onSendFile = {
                switch change {
                case "off": f.provider.config.outboundNotionDataSourceID = ""
                case "family": f.provider.config.groupChatGUIDs = []
                case "source": f.provider.config.outboundNotionDataSourceID = "22222222-2222-4222-8222-222222222222"
                default: f.provider.config.outboundTargets["family"] = "iMessage;+;chat000000000000000002"
                }
            }
            let e = try await f.opened(); _ = await e.pollOutbound()
            XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath())], change)
            XCTAssertTrue(f.h.sender.sent.isEmpty, change)
        }
    }
    func testOB29EditedPendingPageDoesNotResume() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; f.h.lock.locked = true
        let e = try await f.opened(); _ = await e.pollOutbound()
        f.source.entries = [f.row(key: "edited-key", text: "別の本文")]
        f.h.clock.current.addTimeInterval(900); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
        XCTAssertTrue(f.h.state.state.outbound.records.allSatisfy { $0.stage == .terminal })
        XCTAssertTrue(f.h.log.records.contains { $0.code == "outbound_expired" })
    }
}

