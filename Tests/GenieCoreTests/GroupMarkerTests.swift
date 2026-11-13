import XCTest
@testable import GenieCore

final class GroupMarkerTests: XCTestCase {
    func testGC16ConfiguredMarkerIsNormalizedButLegacyMarkerDoesNotReplaceIt() throws {
        let config = try JSONDecoder().decode(GenieConfig.self, from: Data(#"{"marker":"legacy","reply_marker":" 🕊️ "}"#.utf8))
        XCTAssertEqual(config.replyMarker.unicodeScalars.map(\.value), [0x1F54A, 0xFE0F])
        XCTAssertFalse(config.replyMarkerInvalid)
        XCTAssertEqual(ReplyComposer.split(body: "🕊️ answer", marker: config.replyMarker), .send(body: "answer"))
    }

    func testGC17InvalidFlagSurvivesRepeatedSanitizing() throws {
        let invalid = try JSONDecoder().decode(GenieConfig.self, from: Data(#"{"reply_marker":"x🪔"}"#.utf8))
        XCTAssertEqual(invalid.replyMarker, "🧞‍♂️")
        XCTAssertTrue(invalid.replyMarkerInvalid)
        XCTAssertTrue(invalid.sanitized().replyMarkerInvalid)
        let absent = try JSONDecoder().decode(GenieConfig.self, from: Data(#"{"reply_marker":null}"#.utf8))
        XCTAssertFalse(absent.replyMarkerInvalid)
    }

    func testGC18BothMarkersIgnoreVS16AndLeadingInvisibleWhitespace() {
        for marker in ["🕊️", "🕊", "🧞‍♂️", "🧞‍♂"] {
            XCTAssertTrue(ReplyComposer.isReplyMarker(" \u{200B}\(marker) 🪔 request", marker: "🕊️"))
        }
        XCTAssertTrue(ReplyComposer.isReplyMarker("e\u{301} response", marker: "é"))
        XCTAssertFalse(ReplyComposer.isReplyMarker("🪔 request", marker: "🕊️"))
        XCTAssertFalse(ReplyComposer.isReplyMarker("answer 🕊️", marker: "🕊️"))
    }

    func testGC19RepeatedMixedMarkersAndOverlappingPrefixesAreRemovedLongestFirst() {
        for body in ["🕊️ 🧞‍♂ 🕊 🧞‍♂️ answer", "🪔 🕊️ 🧞‍♂️ answer", " \u{200B}🕊️\u{200B}🧞‍♂️answer"] {
            XCTAssertEqual(ReplyComposer.split(body: body, marker: "🕊️"), .send(body: "answer"))
        }
        XCTAssertEqual(ReplyComposer.split(body: "🧞‍♂️ 🧞 🧞‍♂ 🧞 answer", marker: "🧞"), .send(body: "answer"))
        XCTAssertEqual(ReplyComposer.split(body: "🧞‍♂️ 🕊 🧞‍♂ 🕊️", marker: "🕊️"), .emptyBody)
        XCTAssertEqual(ReplyComposer.split(body: "🕊️ 🪔 answer", marker: "🕊️"), .stillSignal)
        XCTAssertEqual(ReplyComposer.split(body: "🕊️ answer", marker: ""), .send(body: "🕊️ answer"))
        XCTAssertEqual(ReplyComposer.split(body: "🧞‍♂️ 🧞‍♂️ answer"), .send(body: "answer"))
    }
}
