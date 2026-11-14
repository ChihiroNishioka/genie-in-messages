import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GenieCore

final class UpdateNetworkTests: XCTestCase {
    func testRequestUsesTheFixedFirstPageEndpointAndHeaders() throws {
        let request = HTTPRequestBuilder.releases()
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.github.com")
        XCTAssertEqual(components.path, "/repos/ChihiroNishioka/genie-in-messages/releases")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "per_page", value: "100")])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "genie-in-messages-update-check")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testRequestDoesNotUseAuthorizationOrCookies() {
        let request = HTTPRequestBuilder.releases()
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testFetcherKeepsOnlyWellFormedEntriesAndRejectsNonArrayJSON() async {
        let body = Data(#"[{"tag_name":"v1.2.0","draft":false,"prerelease":false},{"draft":false,"prerelease":false},{"tag_name":"v1.3.0","draft":false,"prerelease":"no"}]"#.utf8)
        let transport = ScriptedReleaseTransport([.response(.init(statusCode: 200, headers: [:], body: body))])
        let result = await GitHubReleaseFetcher(transport: transport).fetch()
        XCTAssertEqual(result, .success([ReleaseEntry(tag: "v1.2.0", draft: false, prerelease: false)]))

        let invalidTopLevel = ScriptedReleaseTransport([.response(.init(statusCode: 200, headers: [:], body: Data(#"{"message":"invalid"}"#.utf8)))])
        let invalidResult = await GitHubReleaseFetcher(transport: invalidTopLevel).fetch()
        XCTAssertEqual(invalidResult, .failure(.decode, rateLimitReset: nil))
    }

    func testFetcherClassifiesRateLimitAndOtherHTTPStatuses() async {
        let reset = 1_794_614_400.0
        let exhausted = ScriptedReleaseTransport([.response(.init(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(reset))],
            body: Data()
        ))])
        let exhaustedResult = await GitHubReleaseFetcher(transport: exhausted).fetch()
        XCTAssertEqual(
            exhaustedResult,
            .failure(.rateLimited, rateLimitReset: Date(timeIntervalSince1970: reset))
        )

        let tooMany = ScriptedReleaseTransport([.response(.init(statusCode: 429, headers: [:], body: Data()))])
        let tooManyResult = await GitHubReleaseFetcher(transport: tooMany).fetch()
        XCTAssertEqual(tooManyResult, .failure(.rateLimited, rateLimitReset: nil))

        let forbidden = ScriptedReleaseTransport([.response(.init(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "1"],
            body: Data()
        ))])
        let forbiddenResult = await GitHubReleaseFetcher(transport: forbidden).fetch()
        XCTAssertEqual(forbiddenResult, .failure(.http(status: 403), rateLimitReset: nil))
    }

    func testFetcherTurnsTransportErrorsIntoResults() async {
        let transport = ScriptedReleaseTransport([.transportFailure])
        let result = await GitHubReleaseFetcher(transport: transport).fetch()
        XCTAssertEqual(result, .failure(.transport, rateLimitReset: nil))
    }

    func testResponseBodyAndRequestURLDoNotReachMenuOrLogs() async throws {
        let marker = "secret_example_private_response"
        let body = Data(marker.utf8)
        let transport = ScriptedReleaseTransport([.response(.init(statusCode: 503, headers: [:], body: body))])
        let fetcher = GitHubReleaseFetcher(transport: transport)
        let result = await fetcher.fetch()
        XCTAssertEqual(result, .failure(.http(status: 503), rateLimitReset: nil))
        let log = RecordingUpdateLog()
        let checker = UpdateChecker(
            clock: FixedUpdateClock(t0),
            fetcher: ScriptedReleaseFetcher([.immediate(result)]),
            skipStore: MemoryUpdateSkipStore(),
            build: updateCheckBuild(),
            log: log
        )
        await checker.tick()
        await log.waitForEvents(1)
        let snapshot = await checker.snapshot()
        let rows = UpdateMenu.rows(state: snapshot, timeZone: tokyo)
        let events = await log.events
        let text = rows.map(\.displayText).joined(separator: "\n") + "\n" + events.map(\.line).joined(separator: "\n")
        XCTAssertFalse(text.contains(marker))
        XCTAssertFalse(text.contains("api.github.com"))
        XCTAssertFalse(text.contains("localizedDescription"))
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_794_614_400) }
    private var tokyo: TimeZone { TimeZone(identifier: "Asia/Tokyo")! }
}

private struct FixedUpdateClock: GenieClock {
    var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
    func sleep(seconds: Double) async throws {}
}
