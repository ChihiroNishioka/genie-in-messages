import Foundation
import XCTest
@testable import GenieCore

final class OutboundPrivacyTests: XCTestCase {
    func testOB36OutboundLogsAndStateContainNoValues() async throws {
        let f = OutboundHarness(); f.source.entries = [f.row()]; let e = try await f.opened()
        _ = await e.pollOutbound()
        let records = f.h.log.records.filter { $0.code.hasPrefix("outbound_") || $0.code == "reply_sent" }
        XCTAssertFalse(records.isEmpty)
        for record in records { XCTAssertNil(record.chatID); XCTAssertNil(record.guid); XCTAssertNil(record.rowid); XCTAssertNil(record.detail) }
        let json = String(data: try JSONEncoder().encode(f.h.state.state.outbound), encoding: .utf8)!
        XCTAssertFalse(json.contains("お知らせ")); XCTAssertFalse(json.contains("key-0000")); XCTAssertFalse(json.contains("page-0000"))
        XCTAssertFalse(json.contains(OutboundHarness.family)); XCTAssertFalse(json.contains(OutboundHarness.owner))
    }
    func testOB23BodyValidation() async throws {
        let cases: [(String, String)] = [
            ("", "outbound_empty_body"),
            ("🧞‍♂️", "outbound_empty_body"),
            ("🪔 notice", "outbound_signal_body"),
            (" \u{200B}\u{FE0F}🪔 notice", "outbound_signal_body"),
            ("\0", "outbound_text_invalid"),
            (String(repeating: "a", count: 8001), "outbound_text_invalid"),
        ]
        for (i, testCase) in cases.enumerated() {
            let (text, code) = testCase
            let f = OutboundHarness(); f.source.entries = [f.row("page-\(i)", text: text)]
            let e = try await f.opened(); _ = await e.pollOutbound()
            XCTAssertTrue(f.h.sender.outgoing.isEmpty); XCTAssertTrue(f.h.sender.sent.isEmpty)
            XCTAssertTrue(f.h.log.records.contains { $0.code == code }, code)
        }
    }
}
