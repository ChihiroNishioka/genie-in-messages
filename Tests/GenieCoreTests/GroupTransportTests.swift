import XCTest
@testable import GenieCore

final class GroupTransportTests: XCTestCase {
    private let body = "; rm -rf ~ $(id) `x` 'q' \"d\"\n-"

    func testBodyIsOneLiteralArgumentAndEchoDoesNotInterpretIt() async {
        let arguments = ImsgCommand.sendArguments(chatID: 42, text: body)
        XCTAssertEqual(arguments.count, 6)
        XCTAssertEqual(arguments, ["send", "--chat-id", "42", "--text", body, "--json"])
        XCTAssertEqual(arguments.dropFirst(4).first, body)
        let output = await ProcessRunner.run(executable: "/bin/echo", arguments: [body], timeout: 5)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.stdout, body + "\n")
        XCTAssertEqual(output.stderr, "")
    }

    func testPayloadEncodingFailurePrecedesRouteRecording() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/GenieCore/Engine.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    private func deliverWebhook("))
        let end = try XCTUnwrap(source.range(of: "    private func sleepBackoff", range: start.upperBound..<source.endIndex))
        let delivery = String(source[start.lowerBound..<end.lowerBound])
        let route = try XCTUnwrap(delivery.range(of: "rememberRoute(guid:"))
        let beforeRoute = String(delivery[..<route.lowerBound])
        XCTAssertTrue(beforeRoute.contains("do { _ = try encodePayload() }"))
        XCTAssertTrue(beforeRoute.contains("error: \"webhook_encode_failed\", attempts: 0"))
        XCTAssertTrue(delivery[route.upperBound...].contains("body = try encodePayload()"))
    }

    func testSourcesKeepShellAndAppleScriptOutOfMessageDelivery() throws {
        let sources = repoRoot().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["/bin/sh", "osascript", "NSAppleScript", "\"-c\""] {
                XCTAssertFalse(text.contains(forbidden), url.lastPathComponent + " " + forbidden)
            }
        }
    }
}
