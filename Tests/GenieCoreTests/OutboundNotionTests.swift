import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GenieCore

final class OutboundNotionTests: XCTestCase {
    private let sourceID = "11111111-1111-4111-8111-111111111111"
    private let minute = "2023-11-14T22:13:00.000Z"

    func testOB11ExtraAddressColumnsAreIgnored() throws {
        var row = row()
        var props = row["properties"] as! [String: Any]
        props["chat_id"] = ["type": "number", "number": 99]
        props["guid"] = property("rich_text", "iMessage;+;chat000000000000000099")
        props["in_reply_to_guid"] = property("rich_text", "dummy-origin")
        row["properties"] = props
        let result = try OutboundPageDecoder.decode(data([row]), now: ManualClock().now())
        XCTAssertEqual(result.entries.first?.target, .family)
        XCTAssertEqual(result.entries.first?.idempotencyKey, "pigeon-demo-001")
        XCTAssertEqual(result.entries.first?.text, "予定のお知らせ")
        XCTAssertNil(result.entries.first?.invalidCode)
    }

    func testOB33MalformedPropertiesAreTerminalAndUnreadableIdentityFailsFetch() throws {
        for mutation in ["key", "target", "text", "element", "future", "created"] {
            var entry = row()
            var props = entry["properties"] as! [String: Any]
            if mutation == "key" { props["idempotency_key"] = property("title", "invalid key") }
            if mutation == "target" { props["target"] = property("rich_text", "other") }
            if mutation == "text" { props["text"] = ["type": "rich_text", "rich_text": [["plain_text": "valid"], ["type": "broken"]]] }
            if mutation == "element" { props["idempotency_key"] = ["type": "title", "title": [["plain_text": "pigeon-demo-001"]]] }
            if mutation == "created" { props["created_at"] = ["type": "date", "date": ["start": minute]] }
            if mutation == "future" { entry["created_time"] = "2023-11-14T22:15:00Z"; props["created_at"] = ["type": "created_time", "created_time": "2023-11-14T22:15:00Z"] }
            entry["properties"] = props
            let parsed = try OutboundPageDecoder.decode(data([entry]), now: ManualClock().now())
            XCTAssertNotNil(parsed.entries.first?.invalidCode, mutation)
        }
        var noID = row(); noID.removeValue(forKey: "id")
        XCTAssertThrowsError(try OutboundPageDecoder.decode(data([noID]), now: ManualClock().now()))
        var noTime = row(); noTime["created_time"] = "invalid"
        XCTAssertThrowsError(try OutboundPageDecoder.decode(data([noTime]), now: ManualClock().now()))
    }

    func testOB34PagingLookbackAndHoldsUseHashedIndependentCursor() async throws {
        let clock = ManualClock()
        let transport = ScriptedNotion(responses: [
            response([row(id: "page-a")], more: true, next: "next"),
            response([row(id: "page-b", key: "pigeon-demo-002")]),
        ])
        let source = NotionOutboundSource(dataSourceID: sourceID, secrets: StaticSecret(webhook: "dummy", reply: nil, notion: "dummy"), clock: clock, pageLimit: 100, transport: transport, pace: NotionPace())
        let page = try await source.fetch(cursor: nil, skipping: [], holding: [])
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertFalse(page.nextCursor?.contains("page-a") == true)
        let reconciled = OutboundCursor.reconcile(proposed: page.nextCursor, unhandled: [page.entries[0]])
        XCTAssertFalse(NotionCursor.ids(in: reconciled).contains(OutboundHash.digest(kind: "page", values: ["page-a"])))
        XCTAssertEqual(NotionCursor.decode(reconciled)?.notBefore, minute)
        XCTAssertNil(NotionCursor.decode(reconciled)?.seen.first { $0.id == "page-a" })
    }

    func testOB34FreshCursorRejectsBacklogAndKeepsStart() async throws {
        let clock = ManualClock()
        let transport = ScriptedNotion(responses: [response([row(id: "old", at: "2023-11-14T22:12:00Z"), row()])])
        let source = NotionOutboundSource(dataSourceID: sourceID, secrets: StaticSecret(webhook: "dummy", reply: nil, notion: "dummy"), clock: clock, pageLimit: 100, transport: transport, pace: NotionPace())
        let page = try await source.fetch(cursor: nil, skipping: [], holding: [])
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(NotionCursor.decode(page.nextCursor)?.notBefore, minute)
    }

    func testOB35SharedPaceSurvivesBothPreparedSources() async throws {
        let clock = ManualClock()
        let pace = NotionPace()
        let transport = ScriptedNotion(responses: [response([]), response([]), response([])])
        let reply = NotionReplySource(dataSourceID: sourceID, secrets: StaticSecret(webhook: "dummy", reply: nil, notion: "dummy"), clock: clock, pageLimit: 100, transport: transport, pace: pace)
        let outbound = NotionOutboundSource(dataSourceID: sourceID, secrets: StaticSecret(webhook: "dummy", reply: nil, notion: "dummy"), clock: clock, pageLimit: 100, transport: transport, pace: pace)
        _ = try await reply.fetch(cursor: nil)
        _ = try await outbound.fetch(cursor: nil, skipping: [], holding: [])
        _ = try await outbound.prepared(for: GenieConfig.productDefaults).fetch(cursor: nil, skipping: [], holding: [])
        XCTAssertEqual(clock.slept.count, 2)
        XCTAssertTrue(clock.slept.allSatisfy { $0 >= 0.33 })
    }

    func testOB35ConfiguredSourcesRetainOnePaceAcrossPreparation() throws {
        let root = URL(fileURLWithPath: "/tmp/outbound-notion-example")
        let provider = FileConfigProvider(url: root.appendingPathComponent("config.json"))
        let secrets = FileSecretProvider(paths: ConfigPaths(root: root, logFile: root.appendingPathComponent("genie.log")))
        let replies = ConfiguredReplySource(config: provider, secrets: secrets)
        let outbound = ConfiguredOutboundSource(config: provider, secrets: secrets)
        var config = GenieConfig.productDefaults
        config.notionDataSourceID = sourceID
        config.outboundNotionDataSourceID = "22222222-2222-4222-8222-222222222222"
        let first = try XCTUnwrap(replies.prepared(for: config) as? NotionReplySource)
        let second = try XCTUnwrap(outbound.prepared(for: config) as? NotionOutboundSource)
        let recreated = try XCTUnwrap(replies.prepared(for: config) as? NotionReplySource)
        XCTAssertTrue(first.pace === second.pace)
        XCTAssertTrue(first.pace === recreated.pace)
    }

    func testOB35ConcurrentPaceReservationsHaveSeparateSlots() async throws {
        let pace = NotionPace()
        let clock = OutboundPaceClock()
        try await pace.wait(clock)
        async let first: Void = pace.wait(clock)
        async let second: Void = pace.wait(clock)
        _ = try await (first, second)
        let waits = clock.waits.sorted()
        XCTAssertEqual(waits.count, 2)
        XCTAssertEqual(waits[0], NotionAPI.minimumInterval, accuracy: 0.000001)
        XCTAssertEqual(waits[1], NotionAPI.minimumInterval * 2, accuracy: 0.000001)
    }

    func testOB35RetryableFailuresWaitFiveTimesAndStop() async throws {
        let clock = ManualClock()
        let failure = NotionHTTPResponse(status: 529, headers: ["retry-after": "2"], body: Data("{}".utf8))
        let transport = ScriptedNotion(responses: Array(repeating: failure, count: 5))
        let source = NotionOutboundSource(dataSourceID: sourceID, secrets: StaticSecret(webhook: "dummy", reply: nil, notion: "dummy"), clock: clock, pageLimit: 100, transport: transport)
        do {
            _ = try await source.fetch(cursor: nil)
            XCTFail("retry exhaustion must fail")
        } catch {
            guard case ReplyFetchError.transport = error else { return XCTFail("wrong error category") }
        }
        XCTAssertEqual(transport.requests.count, 5)
        XCTAssertEqual(clock.slept, [2, 2, 2, 2, 2])
    }

    private func property(_ type: String, _ text: String) -> [String: Any] {
        ["type": type, type: [["type": "text", "plain_text": text]]]
    }

    private func row(id: String = "page-a", key: String = "pigeon-demo-001", at: String = "2023-11-14T22:13:00.000Z") -> [String: Any] {
        ["object": "page", "id": id, "created_time": at, "properties": [
            "idempotency_key": property("title", key), "target": property("rich_text", "family"),
            "text": property("rich_text", "予定のお知らせ"), "created_at": ["type": "created_time", "created_time": at],
        ]]
    }

    private func data(_ rows: [[String: Any]], more: Bool = false, next: String? = nil) throws -> Data {
        var object: [String: Any] = ["results": rows, "has_more": more]
        if let next { object["next_cursor"] = next }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func response(_ rows: [[String: Any]], more: Bool = false, next: String? = nil) -> NotionHTTPResponse {
        NotionHTTPResponse(status: 200, headers: [:], body: try! data(rows, more: more, next: next))
    }
}

private final class OutboundPaceClock: GenieClock, @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [Double] = []
    var waits: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
    func sleep(seconds: Double) async throws { append(seconds) }
    private func append(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        delays.append(seconds)
    }
}
