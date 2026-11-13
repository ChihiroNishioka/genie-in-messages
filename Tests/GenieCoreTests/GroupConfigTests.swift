import XCTest
@testable import GenieCore

final class GroupConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> GenieConfig {
        try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8))
    }

    private func object(_ config: GenieConfig) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    }

    func testGC01GroupGUIDsNormalizeAndKeepExactCase() throws {
        let config = try decode(#"{"group_chat_guids":[" iMessage;+;chat000000000000000001 ","","  ","iMessage;+;chat000000000000000001","imessage;+;chat000000000000000001"]}"#)
        XCTAssertEqual(try object(config)["group_chat_guids"] as? [String], [
            "iMessage;+;chat000000000000000001", "imessage;+;chat000000000000000001"
        ])
        for json in ["{}", #"{"group_chat_guids":null}"#] {
            XCTAssertEqual(try object(decode(json))["group_chat_guids"] as? [String], [])
        }
        for json in [#"{"group_chat_guids":"bad"}"#, #"{"group_chat_guids":[1]}"#, #"{"group_chat_guids":["ok",null]}"#] {
            XCTAssertThrowsError(try decode(json))
        }
    }

    func testGC02OldMarkerIsSeparateAndNewMarkerDefaults() throws {
        for json in ["{}", #"{"marker":"legacy"}"#, #"{"reply_marker":null}"#] {
            XCTAssertEqual(try object(decode(json))["reply_marker"] as? String, "🧞‍♂️")
        }
        XCTAssertThrowsError(try decode(#"{"reply_marker":123}"#))
    }

    func testGC17MarkerValidationAndNFC() throws {
        let invalid = ["", " \t ", "\u{200B}", "🪔", "x🪔", "\u{200B}🕊️", "a\nb", "a\tb", "a\u{7F}b", "123456789", "a" + String(repeating: "\u{301}", count: 33)]
        for marker in invalid {
            let data = try JSONSerialization.data(withJSONObject: ["reply_marker": marker])
            let config = try JSONDecoder().decode(GenieConfig.self, from: data)
            XCTAssertEqual(try object(config)["reply_marker"] as? String, "🧞‍♂️")
        }
        let valid = try decode(#"{"reply_marker":"  e\u0301  "}"#)
        XCTAssertEqual(try object(valid)["reply_marker"] as? String, "é")
    }
}
