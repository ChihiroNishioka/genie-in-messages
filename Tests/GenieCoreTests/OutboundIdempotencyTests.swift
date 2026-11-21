import Foundation
import XCTest
@testable import GenieCore

final class OutboundIdempotencyTests: XCTestCase {
    func testOB24PageEditingDoesNotCreateNewSend() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try await f.opened()
        _ = await e.pollOutbound()
        f.source.entries = [f.row("page-0001")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        f.source.entries = [f.row("page-0001", key: "new-key", text: "別の本文")]
        _ = await e.pollOutbound(); XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertEqual(f.h.state.state.outbound.records.count, 1)
        XCTAssertEqual(f.h.state.state.outbound.records.first?.pageHashes.count, 2)
    }
    func testOB27LedgerSurvivesJSONReload() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try await f.opened()
        _ = await e.pollOutbound(); f.h.state.state = try reloaded(f.h.state.state).0
        let restarted = try await f.opened(); _ = await restarted.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }
    func testOB28ReservationSavedBeforeFirstSend() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]
        let store = RecordingStateStore()
        f.h.store = store
        f.h.sender.onSendFile = {
            XCTAssertEqual(store.saves.last?.outbound.records.first?.stage, .markerInFlight)
            XCTAssertTrue(store.saves.last?.pendingSends.isEmpty == true)
            XCTAssertTrue(store.saves.last?.partialReplies.isEmpty == true)
        }
        let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }
    func testOB29InterruptedMarkerIsTerminal() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]
        var durable: PersistedState?
        f.h.sender.onSendFile = { durable = f.h.state.state; f.h.stop.stop() }
        let e = try await f.opened(); _ = await e.pollOutbound()
        f.h.sender.onSendFile = nil; f.h.state.state = try XCTUnwrap(durable)
        let restarted = try f.engine(stop: StopSignal()); await restarted.showChats(f.chats)
        _ = await restarted.pollOutbound(); XCTAssertEqual(f.h.sender.outgoing.count, 1)
    }
    func testOB25ConflictingKeyDoesNotOverwrite() async throws {
        let f = OutboundHarness(); f.h.lock.locked = true; f.source.entries = [f.row()]
        let e = try await f.opened(); _ = await e.pollOutbound()
        f.source.entries = [f.row("page-0001", text: "別の本文")]; _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "outbound_idempotency_conflict" })
        f.h.lock.locked = false
        f.h.clock.current.addTimeInterval(60)
        await e.retryHolds()
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ")])
    }
    func testOB26BodyDedupeAndAliasEditing() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try await f.opened()
        _ = await e.pollOutbound()
        f.source.entries = [f.row("page-0001", key: "key-0001")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        f.source.entries = [f.row("page-0001", key: "key-0002", text: "別の本文")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }
    func testOB26BodyDedupeExpiresAndIsPerDestination() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try await f.opened()
        _ = await e.pollOutbound()
        f.source.entries = [f.row("page-0001", key: "key-0001", target: .self)]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 4)
        f.h.clock.current.addTimeInterval(599)
        f.source.entries = [f.row("page-0002", key: "key-0002")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 4)
        f.h.clock.current.addTimeInterval(1)
        f.source.entries = [f.row("page-0003", key: "key-0003")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 6)
        f.h.clock.current.addTimeInterval(86400)
        f.source.entries = [f.row("page-0004", key: "key-0004")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 8)
    }
    func testOB22ExpiredNeverStartsSend() async throws {
        let f = OutboundHarness(); var row = f.row(); row.createdAt = ISO8601.string(from: f.h.clock.now().addingTimeInterval(-900))
        f.source.entries = [row]; let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)

        let boundary = OutboundHarness(); boundary.source.entries = [boundary.row()]
        boundary.h.lock.onState = { boundary.h.clock.current = boundary.h.clock.current.addingTimeInterval(900) }
        let boundaryEngine = try await boundary.opened(); _ = await boundaryEngine.pollOutbound()
        XCTAssertTrue(boundary.h.sender.outgoing.isEmpty)
        XCTAssertTrue(boundary.h.sender.sent.isEmpty)
        XCTAssertTrue(boundary.h.state.state.outbound.records.first?.stage == .terminal)
        XCTAssertEqual(boundary.h.state.state.outbound.records.first?.terminalCode, "outbound_expired")
    }
    func testOB30SaveFailureBlocksSend() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try await f.opened()
        f.h.state.shouldFailSave = true; _ = await e.pollOutbound(); XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
    }
    func testOB31FullLedgerPreservesHistory() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try await f.opened()
        _ = await e.pollOutbound()
        let first = try XCTUnwrap(f.h.state.state.outbound.records.first)
        f.h.state.state.outbound.records = (0..<100000).map { i in var r = first; r.id = "reserved-\(i)"; return r }
        let restarted = try await f.opened()
        f.source.entries = [f.row("page-0001", key: "key-0001", text: "別の本文")]
        _ = await restarted.pollOutbound(); XCTAssertEqual(f.h.sender.outgoing.count, 2)
        XCTAssertEqual(f.h.state.state.outbound.records.count, 100000)
        XCTAssertEqual(f.source.fetchCount, 2)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "outbound_ledger_full" })
    }

    func testOB31BodyReadyResumesAtLedgerLimit() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; f.h.lock.locked = true
        let e = try await f.opened(); _ = await e.pollOutbound()
        var active = f.h.state.state.outbound.records[0]
        active.stage = .bodyReady
        active.chatID = 7
        let fillers = (0..<(OutboundLedger.capacity / 2 - 1)).map { index -> OutboundRecord in
            var record = active
            record.id = "archived-\(index)"
            record.pageHashes = ["archived-page-\(index)"]
            record.stage = .terminal
            record.terminalCode = "outbound_completed"
            record.terminalAt = f.h.clock.now()
            return record
        }
        f.h.state.state.outbound.records = [active] + fillers
        XCTAssertEqual(f.h.state.state.outbound.count, OutboundLedger.capacity)
        let (loaded, _) = try reloaded(f.h.state.state)
        f.h.state.state = loaded
        f.h.lock.locked = false
        let restarted = try await f.opened(); _ = await restarted.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.text("お知らせ")])
        XCTAssertEqual(f.h.state.state.outbound.count, OutboundLedger.capacity)
    }



    func testOB31HistorySurvivesHandledIDsAndSeenOverflow() async throws {
        let f = OutboundHarness()
        f.source.entries = [f.row()]
        let first = try await f.opened()
        _ = await first.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
        f.h.state.state.handledReplyIDs = (0..<5001).map { "reply-\($0)" }
        f.h.state.state.seenGUIDs = (0..<5001).map { "seen-\($0)" }
        let (loaded, _) = try reloaded(f.h.state.state)
        f.h.state.state = loaded
        let second = try await f.opened()
        _ = await second.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }

    func testOB30DeadLetterPendingSurvivesReloadAndRetriesOnTick() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]
        f.h.markerImage = StaticMarkerImage(url: nil)
        f.h.sender.script = [.failure(.failed)]
        f.h.state.shouldFailDeadLetter = true
        let first = try await f.opened(); _ = await first.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 1)
        XCTAssertTrue(f.h.state.state.outbound.records.first?.deadLetterPending == true)
        let (loaded, _) = try reloaded(f.h.state.state)
        let store = MemoryStateStore(state: loaded)
        store.shouldFailDeadLetter = true
        f.h.store = store
        let restarted = try await f.opened()
        XCTAssertTrue(store.state.outbound.records.first?.deadLetterPending == true)
        XCTAssertTrue(store.deadLetters.isEmpty)
        store.shouldFailDeadLetter = false
        _ = await restarted.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 1)
        XCTAssertEqual(store.deadLetters.last?.kind, "outbound")
        XCTAssertEqual(store.deadLetters.last?.error, "outbound_send_failed")
        XCTAssertFalse(store.state.outbound.records.first?.deadLetterPending ?? true)
    }
    func testOB32DatabaseResetDuringMarkerNeverContinuesOrForgetsHistory() async throws {
        let f = OutboundHarness()
        f.source.entries = [f.row()]
        let e = try await f.opened()
        f.h.sender.onSendFile = {
            await e.showChats([ChatSummary(id: 7, title: "family", isGroup: true, guid: "iMessage;+;chat000000000000000002")])
        }
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 1)
        XCTAssertTrue(f.h.sender.sent.isEmpty)
        f.h.sender.onSendFile = nil
        await e.showChats(f.chats)
        _ = await e.pollOutbound()
        f.h.clock.current = f.h.clock.current.addingTimeInterval(20)
        await e.retryHolds()
        XCTAssertEqual(f.h.sender.outgoing.count, 1)
        let restarted = try await f.opened()
        _ = await restarted.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 1)
    }}

