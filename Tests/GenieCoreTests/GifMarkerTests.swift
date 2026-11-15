import XCTest
@testable import GenieCore

final class GifMarkerTests: XCTestCase {
    private var gifURL: URL {
        repoRoot().appendingPathComponent("AppBundle/ReplyMarker/reply-marker.gif")
    }

    func testFirstMessageUsesImageInsteadOfTextMarker() async {
        let h = splitHarness()
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text("こんにちは")])
    }

    func testBundledGifIsTheApprovedOriginal() throws {
        let data = try Data(contentsOf: gifURL)
        let hashes = try String(contentsOf: repoRoot().appendingPathComponent("Tests/GenieCoreTests/Fixtures/approved-hashes.txt"), encoding: .utf8)
        let line = try XCTUnwrap(hashes.split(whereSeparator: \.isNewline).first { $0.hasSuffix("AppBundle/ReplyMarker/reply-marker.gif") })

        XCTAssertEqual(data.count, 65_580)
        XCTAssertEqual(Array(data.prefix(10)), [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x64, 0x00, 0x64, 0x00])
        XCTAssertEqual(SHA256.hex(data), String(line.split(separator: " ").first ?? ""))
    }

    func testFileArgumentsAreLiteralAndHaveNoText() async {
        let path = "/tmp/a b/-x --text y.gif"
        let arguments = ImsgCommand.sendFileArguments(chatID: 7, path: path)

        XCTAssertEqual(arguments, ["send", "--chat-id", "7", "--file", path, "--json"])
        XCTAssertEqual(arguments?.count, 6)
        XCTAssertFalse(arguments?.contains("--text") ?? true)
        XCTAssertEqual(arguments?[4], path)
        guard let arguments else { XCTFail("file arguments missing"); return }
        let output = await ProcessRunner.run(executable: "/bin/echo", arguments: arguments, timeout: 2)
        XCTAssertEqual(output.stdout, arguments.joined(separator: " ") + "\n")
    }

    func testFileArgumentsRejectUnsafePaths() {
        for path in ["", "x.gif", "-x.gif", "/tmp/a\u{0}b.gif", "/tmp/a\nb.gif"] {
            XCTAssertNil(ImsgCommand.sendFileArguments(chatID: 7, path: path), "path: \(path)")
        }
    }

    func testImageCheckClassifiesEachCase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.gif")
        let empty = root.appendingPathComponent("empty.gif")
        let directory = root.appendingPathComponent("directory.gif", isDirectory: true)
        let unreadable = root.appendingPathComponent("unreadable.gif")
        let link = root.appendingPathComponent("link.gif")
        try Data().write(to: empty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data([0x47]).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gifURL)

        XCTAssertEqual(MarkerImage.check(nil), .unavailable(.missing))
        XCTAssertEqual(MarkerImage.check(missing), .unavailable(.missing))
        XCTAssertEqual(MarkerImage.check(empty), .unavailable(.empty))
        XCTAssertEqual(MarkerImage.check(directory), .unavailable(.notRegular))
        XCTAssertEqual(MarkerImage.check(link), .unavailable(.notRegular))
        XCTAssertEqual(MarkerImage.check(URL(string: "relative.gif")), .unavailable(.invalidPath))
        XCTAssertEqual(MarkerImage.check(path: "/tmp/a\u{0}b.gif"), .unavailable(.invalidPath))
        if FileManager.default.isReadableFile(atPath: unreadable.path) {
            throw XCTSkip("the current user can read a mode-zero file")
        }
        XCTAssertEqual(MarkerImage.check(unreadable), .unavailable(.unreadable))
        XCTAssertEqual(MarkerImage.check(gifURL), .usable(path: gifURL.path))
    }

    func testImageSuccessSendsNoTextMarker() async {
        let h = splitHarness()
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text("こんにちは")])
        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text("こんにちは")])
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 1)
        XCTAssertEqual(h.log.records.filter { $0.code == "reply_sent" }.compactMap(\.detail), ["marker_image", "body"])
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
    }

    func testImageFailedFallsBackToMarkerAndContinues() async {
        let h = splitHarness()
        h.sender.script = [
            .failure(.failed),
            .success(SendReceipt(id: 2, guid: "txt-1", status: "sent")),
            .success(SendReceipt(id: 3, guid: "body-1", status: "sent")),
        ]
        guard let engine = await splitOpened(h) else { return }
        var bodySawSavedMarker = false
        h.sender.onSend = {
            guard h.sender.outgoing.last?.item == .text("こんにちは") else { return }
            bodySawSavedMarker = h.state.state.partialReplies.first?.markerGUID == "txt-1"
        }

        await engine.pollReplies()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text(GenieConfig.productDefaults.replyMarker), .text("こんにちは")])
        XCTAssertTrue(bodySawSavedMarker)
        XCTAssertTrue(h.state.state.sentGUIDs.contains("txt-1"))
        XCTAssertTrue(h.state.state.sentGUIDs.contains("body-1"))
        XCTAssertEqual(h.state.state.rateEvents.filter { $0.chatID == 7 }.count, 1)
        XCTAssertEqual(h.log.records.filter { $0.code == "marker_image_failed" }.count, 1)
        XCTAssertTrue(h.state.deadLetters.isEmpty)
    }

    func testImageFailedFallsBackToConfiguredMarker() async {
        let h = splitHarness()
        h.config.replyMarker = "🕊️"
        h.sender.script = [.failure(.failed)]
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text("🕊️"), .text("こんにちは")])
    }

    func testFallbackTextFailureFollowsMarkerRules() async {
        for failure: SendFailure in [.failed, .uncertain, .notStarted] {
            let h = splitHarness()
            h.sender.script = [.failure(.failed), .failure(failure)]
            guard let engine = await splitOpened(h) else { return }

            await engine.pollReplies()

            XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text(GenieConfig.productDefaults.replyMarker)])
            switch failure {
            case .failed:
                XCTAssertEqual(h.state.deadLetters.last?.error, "send_failed")
                XCTAssertTrue(h.state.state.rateEvents.isEmpty)
                XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
            case .uncertain:
                XCTAssertEqual(h.state.deadLetters.last?.error, "send_uncertain")
                XCTAssertEqual(h.state.state.rateEvents.count, 1)
                XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
            case .notStarted:
                let snapshot = await engine.snapshot()
                XCTAssertEqual(snapshot.heldLockCount, 1)
                XCTAssertEqual(snapshot.lastError, "apple_event_1712")
                XCTAssertTrue(h.state.state.rateEvents.isEmpty)
                h.clock.current = h.clock.current.addingTimeInterval(15)
                await engine.retryHolds()
                XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text(GenieConfig.productDefaults.replyMarker), .file(gifURL.path), .text("こんにちは")])
            }
        }
    }

    func testImageUncertainSendsNothingMore() async {
        let outcomes: [Result<SendReceipt, SendFailure>] = [
            .failure(.uncertain),
            .success(SendReceipt(id: 1, guid: "", status: "sent")),
        ]
        for outcome in outcomes {
            let h = splitHarness()
            h.sender.script = [outcome]
            guard let engine = await splitOpened(h) else { return }

            await engine.pollReplies()
            h.clock.current = h.clock.current.addingTimeInterval(15)
            await engine.retryHolds()
            await engine.pollReplies()

            XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path)])
            XCTAssertEqual(h.state.deadLetters.last?.error, "send_uncertain")
            XCTAssertEqual(h.state.state.rateEvents.count, 1)
            XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
            XCTAssertTrue(h.state.state.partialReplies.isEmpty)
            XCTAssertTrue(h.log.records.contains { $0.code == "send_uncertain" && $0.detail == "marker_image" })
        }
    }

    func testImageNotStartedHoldsAndRetriesImageFirst() async {
        let h = splitHarness()
        h.sender.script = [.failure(.notStarted)]
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()
        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path)])
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.heldLockCount, 1)
        XCTAssertEqual(snapshot.lastError, "apple_event_1712")
        XCTAssertTrue(h.state.state.rateEvents.isEmpty)
        XCTAssertTrue(h.state.state.partialReplies.isEmpty)
        XCTAssertTrue(h.log.records.contains { $0.code == "apple_event_1712" && $0.detail == "marker_image" })

        h.clock.current = h.clock.current.addingTimeInterval(15)
        await engine.retryHolds()
        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .file(gifURL.path), .text("こんにちは")])
        XCTAssertEqual(h.state.state.rateEvents.count, 1)
    }

    func testRetryUsesTextWhenImageWentMissing() async {
        let h = splitHarness()
        h.sender.script = [.failure(.notStarted)]
        let image = MutableMarkerImage(url: gifURL)
        h.markerImage = image
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()
        image.url = nil
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await engine.retryHolds()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text(GenieConfig.productDefaults.replyMarker), .text("こんにちは")])
    }

    func testUnavailableImageFallsBackWithoutLaunching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.gif")
        let directory = root.appendingPathComponent("directory.gif", isDirectory: true)
        let link = root.appendingPathComponent("link.gif")
        try Data().write(to: empty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gifURL)
        let cases: [(URL?, MarkerImageUnavailable)] = [
            (nil, .missing),
            (empty, .empty),
            (directory, .notRegular),
            (root.appendingPathComponent("missing.gif"), .missing),
            (URL(string: "relative.gif"), .invalidPath),
            (link, .notRegular),
        ]

        for (url, reason) in cases {
            let h = splitHarness()
            h.markerImage = StaticMarkerImage(url: url)
            guard let engine = await splitOpened(h) else { return }

            await engine.pollReplies()

            XCTAssertEqual(h.sender.sentFiles.count, 0)
            XCTAssertEqual(h.sender.outgoing.map(\.item), [.text(GenieConfig.productDefaults.replyMarker), .text("こんにちは")])
            XCTAssertTrue(h.log.records.contains { $0.code == "marker_image_unavailable" && $0.level == "warning" && $0.detail == reason.rawValue })
            if let path = url?.path {
                XCTAssertFalse(h.log.records.contains { $0.detail == path })
            }
        }
    }

    func testUnavailableImageLogsOnceUntilResolved() async {
        let h = splitHarness()
        let image = MutableMarkerImage(url: nil)
        h.markerImage = image
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()
        h.replies.pages = [ReplyPage(replies: [routedReply("r2", chat: 7, text: "次", guid: "origin")], nextCursor: nil)]
        await engine.pollReplies()
        XCTAssertEqual(h.log.records.filter { $0.code == "marker_image_unavailable" }.count, 1)

        image.url = gifURL
        h.replies.pages = [ReplyPage(replies: [routedReply("r3", chat: 7, text: "三", guid: "origin")], nextCursor: nil)]
        await engine.pollReplies()
        image.url = nil
        h.replies.pages = [ReplyPage(replies: [routedReply("r4", chat: 7, text: "四", guid: "origin")], nextCursor: nil)]
        await engine.pollReplies()

        XCTAssertEqual(h.log.records.filter { $0.code == "marker_image_unavailable" }.count, 2)
    }

    func testPauseAfterImageFailureHoldsWithoutText() async {
        let h = splitHarness()
        h.sender.script = [.failure(.failed)]
        guard let engine = await splitOpened(h) else { return }
        h.sender.onSendFile = { await engine.setPaused(true) }

        await engine.pollReplies()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path)])
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.heldLockCount, 1)
        XCTAssertTrue(h.state.state.rateEvents.isEmpty)
        await engine.setPaused(false)
        h.sender.onSendFile = nil
        h.clock.current = h.clock.current.addingTimeInterval(15)
        await engine.retryHolds()
        XCTAssertEqual(h.sender.outgoing.map(\.item).first, .file(gifURL.path))
    }

    func testDatabaseResetDuringImageDropsTheBody() async {
        let h = splitHarness()
        guard let engine = await splitOpened(h) else { return }
        h.sender.onSendFile = {
            await engine.showChats([ChatSummary(id: 7, title: "room", isGroup: false, guid: "chat-new")])
            h.sender.onSendFile = nil
        }

        await engine.pollReplies()

        XCTAssertTrue(h.state.state.sentGUIDs.contains("sent-1"))
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
        XCTAssertTrue(h.state.state.partialReplies.isEmpty)
        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path)])
        XCTAssertTrue(h.log.records.contains { $0.code == "reply_dropped_db_reset" && $0.detail == "marker" })
    }

    func testImageThrowFallsBackLikeFailed() async {
        let h = splitHarness()
        h.sender.throwNext = UnrelatedSendError()
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.file(gifURL.path), .text(GenieConfig.productDefaults.replyMarker), .text("こんにちは")])
        XCTAssertEqual(h.log.records.filter { $0.code == "marker_image_failed" && $0.level == "warning" }.count, 1)
    }

    func testImageGuidIsIgnoredWhenWatchEchoesIt() async {
        let h = splitHarness()
        guard let engine = await splitOpened(h) else { return }
        await engine.pollReplies()

        let result = await engine.ingestWatchLine(watchLine(
            id: 2, guid: "sent-1", chat: 7, fromMe: true, text: "🪔 test"
        ))

        XCTAssertEqual(result, .ignoredSentGUID)
        XCTAssertTrue(h.webhook.bodies.isEmpty)
    }

    func testAttachmentOnlyEchoIsNotASignal() async throws {
        let h = splitHarness()
        guard let engine = await splitOpened(h) else { return }

        for (index, text) in ["", "\u{FFFC}"].enumerated() {
            let result = await engine.ingestWatchLine(watchLine(
                id: 40 + index, guid: "attachment-\(index)", chat: 7, fromMe: false, text: text
            ))
            XCTAssertEqual(result, .ignoredNoSignal)
        }
        XCTAssertTrue(h.webhook.bodies.isEmpty)
        XCTAssertTrue(h.sender.outgoing.isEmpty)
    }

    func testImageMarkerAddsNoEmojiFingerprint() async {
        let h = splitHarness()
        guard let engine = await splitOpened(h) else { return }
        var pendingMarkerHasImageKind = false
        h.sender.onSendFile = {
            pendingMarkerHasImageKind = h.state.state.pendingSends.contains {
                $0.part == .marker && $0.markerKind == .image && $0.hash.isEmpty
            }
        }

        await engine.pollReplies()

        let markerHash = SHA256.hex(Data(GenieConfig.productDefaults.replyMarker.utf8))
        XCTAssertTrue(pendingMarkerHasImageKind)
        XCTAssertFalse(h.state.state.fingerprints.contains { $0.hash == markerHash })
        XCTAssertTrue(h.state.state.fingerprints.contains { $0.hash == SHA256.hex(Data("こんにちは".utf8)) })
        let result = await engine.ingestWatchLine(watchLine(
            id: 3, guid: "other", chat: 7, fromMe: true, text: GenieConfig.productDefaults.replyMarker
        ))
        XCTAssertEqual(result, .ignoredReplyMarker)
    }

    func testInterruptedImageMarkerAddsNoFingerprint() throws {
        let h = Harness()
        h.state.state.pendingSends = [PendingSend(
            replyID: "r1", chatID: 7, hash: "", at: h.clock.current,
            rateCounted: true, part: .marker, markerKind: .image
        )]

        _ = try h.engine()

        XCTAssertTrue(h.state.state.fingerprints.isEmpty)
        XCTAssertTrue(h.state.deadLetters.contains { $0.error == "send_interrupted" })
        XCTAssertTrue(h.state.state.handledReplyIDs.contains("r1"))
    }

    func testRestartAfterImageSendsOnlyTheBody() async {
        let h = splitHarness()
        h.state.state.partialReplies = [PartialReply(replyID: "r1", chatID: 7, markerGUID: "sent-1", at: h.clock.current)]
        guard let engine = await splitOpened(h) else { return }

        await engine.pollReplies()

        XCTAssertEqual(h.sender.outgoing.map(\.item), [.text("こんにちは")])
        XCTAssertTrue(h.sender.sentFiles.isEmpty)
    }
}

private final class MutableMarkerImage: MarkerImageLocating, @unchecked Sendable {
    var url: URL?
    init(url: URL?) { self.url = url }
    func markerImageURL() -> URL? { url }
}

private struct UnrelatedSendError: Error {}
