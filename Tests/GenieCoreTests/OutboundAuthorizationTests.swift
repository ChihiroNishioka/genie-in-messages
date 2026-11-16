import Foundation
import XCTest
@testable import GenieCore

final class OutboundAuthorizationTests: XCTestCase {
    func testOB04SelfWithParticipantProof() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row(target: .self)]
        let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.chatID), [8, 8])
    }
    func testOB05UnknownTargetAndUnsetTarget() async throws {
        let f = OutboundHarness(); var bad = f.row(); bad.target = nil
        f.source.entries = [bad]; let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
        f.source.entries = [f.row("page-0001", key: "key-0001", text: "別のお知らせ")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }
    func testOB06FamilyRequiresConfiguredGroup() async throws {
        let f = OutboundHarness(); f.provider.config.groupChatGUIDs = []
        f.h.allow.ids.insert(7); f.h.allow.guids[7] = OutboundHarness.family
        f.source.entries = [f.row()]; let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
        f.provider.config.groupChatGUIDs = [OutboundHarness.family]
        // 正の対照は別の本文にする（同じ宛先・同じ本文は 600 秒の抑止に当たるため。仕様 9.1）
        f.source.entries = [f.row("page-0001", key: "key-0001", text: "別のお知らせ")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }
    func testOB06FamilyRejectsNonGroup() async throws {
        let f = OutboundHarness(); f.provider.config.outboundTargets["family"] = OutboundHarness.owner
        f.provider.config.groupChatGUIDs = [OutboundHarness.owner]
        f.source.entries = [f.row()]; let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
    }
    func testOB07SelfRequiresPositiveProof() async throws {
        let f = OutboundHarness(); f.provider.config.selfChatIDs = []
        var chats = f.chats
        chats[1].participantsKnown = true
        chats[1].participants = ["other@example.com"]
        chats[1].lastAddressedHandle = "owner@example.com"
        let e = try f.engine(); await e.showChats(chats)
        f.source.entries = [f.row(target: .self)]; _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
        f.provider.config.selfChatIDs = [8]
        f.source.entries = [f.row("page-0001", key: "key-0001", target: .self, text: "別のお知らせ")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }

    func testOB07SelfRejectsGroupEvenWhenSelfChatIDAllowsIt() async throws {
        let f = OutboundHarness()
        f.provider.config.selfChatIDs = [9]
        f.provider.config.outboundTargets["self"] = "iMessage;+;chat000000000000000003"
        f.h.allow.ids.insert(9)
        f.h.allow.guids[9] = "iMessage;+;chat000000000000000003"
        let group = ChatSummary(id: 9, title: "group", isGroup: true, guid: "iMessage;+;chat000000000000000003")
        let e = try f.engine(); await e.showChats(f.chats + [group])
        f.source.entries = [f.row(target: .self)]
        _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty)
        XCTAssertTrue(f.h.sender.sent.isEmpty)
    }
    func testOB13DirectoryRequiredAndRecovery() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try f.engine()
        _ = await e.pollOutbound(); XCTAssertEqual(f.source.fetchCount, 0)
        await e.showChats([]); _ = await e.pollOutbound(); XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
        await e.showChats(f.chats); _ = await e.pollOutbound(); XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }

    func testOB09AmbiguousGUIDHoldsWithoutChoosingFirstChat() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]
        let e = try await f.opened()
        let duplicate = ChatSummary(id: 9, title: "duplicate", isGroup: true, guid: OutboundHarness.family)
        await e.showChats(f.chats + [duplicate])
        _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty)
        XCTAssertTrue(f.h.sender.sent.isEmpty)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "outbound_target_ambiguous" })
        await e.showChats(f.chats)
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }
    func testOB10AllPermissionGUIDsMustMatch() async throws {
        let f = OutboundHarness(); f.h.allow.ids.insert(7); f.h.allow.guids[7] = OutboundHarness.family
        f.source.entries = [f.row()]; let e = try await f.opened()
        await e.setChatEnabled(8, guid: "iMessage;-;other@example.com", enabled: true)
        f.source.entries = [f.row(target: .self)]; _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
    }
    func testOB08EffectivePermissionRequired() async throws {
        let f = OutboundHarness(); f.h.allow.ids = []
        f.source.entries = [f.row(target: .self)]; let e = try await f.opened(); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
        await e.setChatEnabled(8, guid: OutboundHarness.owner, enabled: true)
        f.source.entries = [f.row("page-0001", key: "key-0001", target: .self, text: "別のお知らせ")]; _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.count, 2)
    }
    func testOB12ReservationNeverRetargets() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; f.h.lock.locked = true
        let e = try await f.opened(); _ = await e.pollOutbound()
        f.provider.config.outboundTargets["family"] = "iMessage;+;chat000000000000000002"
        f.h.lock.locked = false; f.h.clock.current.addTimeInterval(60)
        await e.retryHolds(); _ = await e.pollOutbound()
        XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
    }



    func testOB04AutomaticSelfProofSendsOnlyToOwner() async throws {
        let f = OutboundHarness()
        f.provider.config.selfChatIDs = []
        f.source.entries = [f.row(target: .self)]
        var chats = f.chats
        chats[1].participantsKnown = true
        chats[1].participants = ["owner@example.com"]
        chats[1].lastAddressedHandle = "owner@example.com"
        let e = try f.engine()
        await e.showChats(chats)
        _ = await e.pollOutbound()
        XCTAssertEqual(f.h.sender.outgoing.map(\.chatID), [8, 8])
        XCTAssertEqual(f.h.sender.outgoing.map(\.item), [.file(expectedGIFPath()), .text("お知らせ")])
    }
    func testOB12SelfEvidenceChangesBetweenPartsAreTerminal() async throws {
        for change in ["participant", "own_handle", "forced"] {
            let f = OutboundHarness()
            f.provider.config.selfChatIDs = change == "forced" ? [8] : []
            f.source.entries = [f.row(target: .self)]
            var chats = f.chats
            chats[1].participantsKnown = true
            chats[1].participants = ["owner@example.com"]
            chats[1].lastAddressedHandle = "owner@example.com"
            let e = try f.engine()
            await e.showChats(chats)
            let original = chats
            f.h.sender.onSendFile = {
                var changed = original
                if change == "participant" { changed[1].participants = ["other@example.com"] }
                if change == "own_handle" { changed[1].lastAddressedHandle = "other@example.com" }
                if change == "forced" { f.provider.config.selfChatIDs = [] }
                await e.showChats(changed)
            }
            _ = await e.pollOutbound()
            XCTAssertEqual(f.h.sender.outgoing.count, 1, change)
            XCTAssertTrue(f.h.sender.sent.isEmpty, change)
            f.h.sender.onSendFile = nil
            await e.showChats(original)
            f.provider.config.selfChatIDs = [8]
            _ = await e.pollOutbound()
            XCTAssertEqual(f.h.sender.outgoing.count, 1, change)
        }
    }}

