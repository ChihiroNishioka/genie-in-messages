import XCTest
@testable import GenieCore

extension SplitReplyTests {
    func testSelfChatInboundEchoesAreIgnored() async {
        let h = splitHarness()
        h.config.selfChatIDs = [7]
        guard let e = await splitOpened(h) else { return }
        await e.pollReplies()
        XCTAssertEqual(h.sender.sent.count, 2)

        var results: [IngestResult] = []
        let sentCount = min(h.sender.sent.count, 2)
        for index in 0..<sentCount {
            guard h.sender.sent.indices.contains(index) else {
                XCTFail("sent entry \(index) missing")
                return
            }
            let item = h.sender.sent[index]
            let sentGUID = "sent-\(index + 1)"
            let own = await e.ingestWatchLine(watchLine(
                id: 100 + index * 2, guid: sentGUID, chat: 7, fromMe: true, text: item.text,
                created: "2023-11-14T22:13:20.000Z", isGroup: false, participants: ["me"]
            ))
            let received = await e.ingestWatchLine(watchLine(
                id: 101 + index * 2, guid: "echo-\(index + 1)", chat: 7, fromMe: false, text: item.text,
                created: "2023-11-14T22:13:20.090Z", isGroup: false, participants: ["me"]
            ))
            results.append(own)
            results.append(received)
        }

        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results, [.ignoredSentGUID, .ignoredFingerprint, .ignoredSentGUID, .ignoredFingerprint])
        XCTAssertFalse(results.contains(.duplicate))
        XCTAssertTrue(h.webhook.bodies.isEmpty)
        XCTAssertTrue(h.state.deadLetters.isEmpty)
    }
}
