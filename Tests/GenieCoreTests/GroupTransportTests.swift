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
