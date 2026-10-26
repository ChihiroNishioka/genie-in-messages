import XCTest
@testable import GenieCore

final class SignalTests: XCTestCase {
    func testLampAloneAndWithVariationSelector() {
        XCTAssertTrue(Signal.matches("\u{1FA94}"))
        XCTAssertTrue(Signal.matches("\u{1FA94}\u{FE0F}"))
        XCTAssertTrue(Signal.matches(" \n\t\u{1FA94} go"))
        XCTAssertTrue(Signal.matches("\u{FE0F}\u{1FA94}"))
        let scan = Signal.scan("\u{1FA94}\u{FE0F} hi")
        XCTAssertTrue(scan.matched)
        XCTAssertEqual(scan.remainder, " hi")
        XCTAssertFalse(Signal.matches("go \u{1FA94}"))
        XCTAssertFalse(Signal.matches(""))
        XCTAssertFalse(Signal.matches("   "))
    }

    func testGenieFormsAreNotSignals() {
        XCTAssertFalse(Signal.matches("\u{1F9DE}"))
        XCTAssertFalse(Signal.matches("\u{1F9DE}\u{FE0F}"))
        XCTAssertFalse(Signal.matches("\u{1F9DE}\u{200D}\u{2640}"))
        XCTAssertFalse(Signal.matches("\u{1F9DE}\u{200D}\u{2640}\u{FE0F}"))
        XCTAssertFalse(Signal.matches("\u{1F9DE}\u{200D}\u{2642}"))
        XCTAssertFalse(Signal.matches("\u{1F9DE}\u{200D}\u{2642}\u{FE0F}"))
        XCTAssertFalse(Signal.matches("\u{1F9DE}\u{200D}\u{2642}\u{FE0F} hi"))
    }

    func testNFDTextStillMatchesThePrefix() {
        let text = "\u{1FA94} \u{3066}\u{3099}"
        XCTAssertTrue(Signal.matches(text))
        XCTAssertEqual(TextNormalizer.nfc(text).unicodeScalars.map(\.value).last, 0x3067)
    }

    func testComposerStripsSignalAndForcesMarker() {
        let marker = GenieConfig.productDefaults.marker
        let prepared = ReplyComposer.prepare(body: "\u{1FA94}\u{FE0F} 返事", marker: marker)
        XCTAssertFalse(Signal.matches(prepared))
        XCTAssertTrue(prepared.hasPrefix(marker))
        XCTAssertTrue(prepared.contains("返事"))
        XCTAssertEqual(ReplyComposer.prepare(body: "\u{1FA94}", marker: marker), marker)
        XCTAssertEqual(ReplyComposer.prepare(body: "hello", marker: marker), marker + " hello")
    }

    func testComposerDoesNotDoubleTheMarker() {
        let marker = GenieConfig.productDefaults.marker
        let prepared = ReplyComposer.prepare(body: marker + " hi", marker: marker)
        XCTAssertEqual(prepared, marker + " hi")
        XCTAssertFalse(Signal.matches(prepared))
    }

    func testLampMarkerIsReplacedWithTheDefault() {
        let prepared = ReplyComposer.prepare(body: "hello", marker: "\u{1FA94}")
        XCTAssertFalse(Signal.matches(prepared))
        XCTAssertTrue(prepared.hasPrefix(GenieConfig.productDefaults.marker))
        XCTAssertTrue(prepared.contains("hello"))
        var config = GenieConfig.productDefaults
        config.marker = "\u{1FA94}\u{FE0F} hi"
        XCTAssertEqual(config.sanitized().marker, GenieConfig.productDefaults.marker)
    }

    func testDefaultMarkerMatchesTheSpecScalars() {
        XCTAssertEqual(
            Array(GenieConfig.productDefaults.marker.unicodeScalars.map(\.value)),
            [0x1F9DE, 0x200D, 0x2642, 0xFE0F]
        )
        XCTAssertFalse(Signal.matches(GenieConfig.productDefaults.marker))
    }
}

final class HashAndCommandTests: XCTestCase {
    func testSHA256KnownVector() {
        XCTAssertEqual(
            SHA256.hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testImsgCommandsUseLibexecArgumentsOnly() {
        XCTAssertEqual(ImsgCommand.watchArguments(sinceRowID: 0), ["watch", "--json"])
        XCTAssertEqual(
            ImsgCommand.watchArguments(sinceRowID: 9),
            ["watch", "--json", "--since-rowid", "9"]
        )
        XCTAssertEqual(
            ImsgCommand.sendArguments(chatID: 3, text: "hi"),
            ["send", "--chat-id", "3", "--text", "hi", "--json"]
        )
        XCTAssertEqual(
            ImsgCommand.chatsArguments(limit: 100),
            ["chats", "--json", "--limit", "100"]
        )
        XCTAssertEqual(
            GenieConfig.productDefaults.imsgExecutable,
            "/opt/homebrew/opt/imsg/libexec/imsg"
        )
        XCTAssertFalse(GenieConfig.productDefaults.imsgExecutable.contains("/bin/imsg"))
    }

    func testSendParser() {
        let sent = SendResultParser.parse(
            stdout: "{\"id\":10,\"status\":\"sent\",\"guid\":\"G-1\"}\n",
            stderr: "",
            exitCode: 0
        )
        XCTAssertEqual(try sent.get().guid, "G-1")
        XCTAssertEqual(try sent.get().id, 10)

        XCTAssertEqual(
            SendResultParser.parse(stdout: "", stderr: "AppleScript error -1712 (not_started)", exitCode: 1),
            .failure(.notStarted)
        )
        XCTAssertEqual(
            SendResultParser.parse(stdout: "{\"status\":\"not_started\"}", stderr: "", exitCode: 1),
            .failure(.notStarted)
        )
        XCTAssertEqual(
            SendResultParser.parse(stdout: "{\"status\":\"may_have_completed\"}", stderr: "error -1712", exitCode: 1),
            .failure(.uncertain)
        )
        XCTAssertEqual(
            SendResultParser.parse(stdout: "{\"status\":\"still_in_flight\"}", stderr: "", exitCode: 1),
            .failure(.uncertain)
        )
        XCTAssertEqual(
            SendResultParser.parse(stdout: "{\"status\":\"sent\"}", stderr: "", exitCode: 0),
            .failure(.uncertain)
        )
        XCTAssertEqual(
            SendResultParser.parse(stdout: "nope", stderr: "", exitCode: 1),
            .failure(.failed)
        )
        XCTAssertEqual(
            SendResultParser.parse(stdout: "", stderr: "error -1712", exitCode: 1),
            .failure(.uncertain)
        )
        XCTAssertEqual(
            SendLaunch.interpret(stdout: "", stderr: "", exitCode: -1, timedOut: false),
            .failure(.notStarted)
        )
        XCTAssertEqual(
            SendLaunch.interpret(stdout: "", stderr: "", exitCode: 1, timedOut: true),
            .failure(.uncertain)
        )
    }

    func testChatParserIgnoresHandles() {
        let line = #"{"id":4,"name":"","display_name":"","identifier":"handle-not-a-title","participants":["handle-not-a-title"],"is_group":true}"#
        let chat = ChatListParser.parseLine(line)
        XCTAssertEqual(chat?.id, 4)
        XCTAssertEqual(chat?.title, "トーク 4")
        XCTAssertEqual(chat?.isGroup, true)

        let named = #"{"id":5,"name":"メモ","identifier":"handle-not-a-title","is_group":false}"#
        XCTAssertEqual(ChatListParser.parseLine(named)?.title, "メモ")
    }

    func testReplyRequestKeepsTheTokenOutOfTheURL() throws {
        let request = try XCTUnwrap(
            HTTPRequestBuilder.reply(
                url: URL(string: "http://127.0.0.1/replies")!,
                cursor: "a b",
                secret: "tok"
            )
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertFalse(request.url?.absoluteString.contains("tok") ?? true)
        XCTAssertTrue(request.url?.query?.contains("cursor=") ?? false)
        XCTAssertNil(request.httpBody)
    }

    func testReplyPageDecoder() throws {
        let json = #"{"v":1,"cursor":"c2","replies":[{"id":"r1","chat_id":7,"text":"hi","in_reply_to_guid":"g","created_at":"2026-10-26T01:00:00Z"},{"text":"broken"}]}"#
        let page = try ReplyPageDecoder.decode(Data(json.utf8))
        XCTAssertEqual(page.nextCursor, "c2")
        XCTAssertEqual(page.replies.first?.chatID, 7)
        XCTAssertEqual(page.replies.first?.inReplyToGUID, "g")
        XCTAssertEqual(page.replies.first?.createdAt, "2026-10-26T01:00:00Z")
        XCTAssertEqual(page.skipped, 1)
        XCTAssertEqual(page.replies.count, 1)
    }
}
