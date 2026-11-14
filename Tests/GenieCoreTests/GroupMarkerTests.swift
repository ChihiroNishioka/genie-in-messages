import XCTest
@testable import GenieCore

final class GroupMarkerTests: XCTestCase {
    func testReplyMarkerRequiresEmojiFirstGraphemeAndReportsInvalidWithoutTruncatingText() async throws {
        for raw in ["A", "あ", "#", "🕊", "A\u{FE0F}", "A🕊️", "#🕊️"] {
            let data = try JSONSerialization.data(withJSONObject: ["reply_marker": raw])
            let config = try JSONDecoder().decode(GenieConfig.self, from: data)
            XCTAssertEqual(config.replyMarker, ReplyComposer.markerText, raw)
            XCTAssertTrue(config.replyMarkerInvalid, raw)
            XCTAssertEqual(ReplyComposer.split(body: raw + " answer", marker: config.replyMarker), .send(body: raw + " answer"), raw)
            let h = Harness()
            h.config = config
            let e = try h.engine()
            let received = await e.ingestWatchLine(watchLine(id: 1, guid: "ordinary-marker", chat: 42, fromMe: true, text: raw + " answer"))
            XCTAssertEqual(received, .ignoredNoSignal, raw)
            XCTAssertEqual(h.log.records.filter { $0.code == "reply_marker_invalid" }.count, 1, raw)
        }
        for raw in ["🕊️", "🧞", "🧞‍♂️", "#️⃣"] {
            let data = try JSONSerialization.data(withJSONObject: ["reply_marker": raw])
            let config = try JSONDecoder().decode(GenieConfig.self, from: data)
            XCTAssertEqual(config.replyMarker, raw)
            XCTAssertFalse(config.replyMarkerInvalid, raw)
            XCTAssertEqual(ReplyComposer.split(body: raw + " answer", marker: config.replyMarker), .send(body: "answer"), raw)
        }
    }

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
