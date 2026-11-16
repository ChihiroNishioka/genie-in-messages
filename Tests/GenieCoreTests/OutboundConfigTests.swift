import XCTest
@testable import GenieCore

final class OutboundConfigTests: XCTestCase {
    func testOB01MissingNullAndEmptyDisableOutbound() throws {
        for json in ["{}", "{\"outbound_notion_data_source_id\":null,\"outbound_targets\":null,\"outbound_max_age_seconds\":null}", "{\"outbound_notion_data_source_id\":\"  \"}"] {
            let config = try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8))
            XCTAssertEqual(config.outboundNotionDataSourceID, "")
            XCTAssertEqual(config.outboundTargets, [:])
            XCTAssertEqual(config.outboundMaxAgeSeconds, 900)
            XCTAssertFalse(config.outboundEnabled)
        }
    }

    func testOB02StrictOutboundConfiguration() throws {
        for json in [
            "{\"outbound_targets\":{\"other\":\"dummy\"}}",
            "{\"outbound_targets\":{\"family\":1}}",
            "{\"outbound_targets\":[]}",
            "{\"outbound_max_age_seconds\":59}",
            "{\"outbound_max_age_seconds\":3601}",
            "{\"outbound_max_age_seconds\":900.5}",
            "{\"outbound_max_age_seconds\":\"900\"}",
            "{\"outbound_notion_data_source_id\":\"invalid\"}",
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8)))
        }
        let json = "{\"outbound_targets\":{\"self\":\" iMessage;-;owner@example.com \",\"family\":\" \"},\"outbound_max_age_seconds\":60}"
        let config = try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.outboundTargets, ["self": "iMessage;-;owner@example.com"])
        XCTAssertEqual(config.outboundMaxAgeSeconds, 60)
    }

    func testOB02CanonicalSourceConflictOnlyDisablesOutbound() throws {
        let json = "{\"notion_data_source_id\":\"11111111-1111-4111-8111-111111111111\",\"outbound_notion_data_source_id\":\"11111111111141118111111111111111\"}"
        let config = try JSONDecoder().decode(GenieConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.outboundSourceConflict)
        XCTAssertFalse(config.outboundEnabled)
        XCTAssertFalse(config.notionDataSourceID.isEmpty)
    }

    func testOB09TargetCollisionIsDetected() throws {
        for pair in [
            ("iMessage;+;chat000000000000000001", "iMessage;+;chat000000000000000001"),
            ("iMessage;+;chat000000000000000001", "imessage;+;chat000000000000000001"),
        ] {
            var config = GenieConfig.productDefaults
            config.outboundTargets = ["family": pair.0, "self": pair.1]
            XCTAssertTrue(config.sanitized().outboundTargetCollision)
        }
    }
}
