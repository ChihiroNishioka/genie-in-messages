import Foundation
import XCTest
@testable import GenieCore

final class UpdateMenuTests: XCTestCase {
    func testAvailableRowsHaveValidatedReleaseLinkSkipAndTokyoTimestamp() {
        let snapshot = UpdateSnapshot(
            build: updateCheckBuild(),
            decision: .available(updateCheckVersion("1.2.0")),
            lastAttemptAt: t0,
            failure: nil,
            rateLimitReset: nil,
            phase: .idle
        )
        XCTAssertEqual(UpdateMenu.rows(state: snapshot, timeZone: tokyo), [
            .action("新しいバージョン v1.2.0 があります", .openRelease(updateCheckVersion("1.2.0"))),
            .action("このバージョンはスキップ", .skip(updateCheckVersion("1.2.0"))),
            .label("確認: 11/14 09:00"),
            .action("アップデートを確認", .checkNow),
        ])
    }

    func testUpToDateAndSkippedDecisionsAreDisabledRows() {
        let current = updateCheckVersion("1.1.0")
        let upToDate = UpdateSnapshot(build: .release(current), decision: .upToDate(current), lastAttemptAt: nil, failure: nil, rateLimitReset: nil, phase: .idle)
        XCTAssertTrue(UpdateMenu.rows(state: upToDate, timeZone: tokyo).contains(.label("最新です（v1.1.0）")))
        XCTAssertEqual(UpdateMenu.rows(state: upToDate, timeZone: tokyo).compactMap(\.action), [.checkNow])

        let skipped = UpdateSnapshot(build: .release(current), decision: .skipped(updateCheckVersion("1.2.0")), lastAttemptAt: nil, failure: nil, rateLimitReset: nil, phase: .idle)
        XCTAssertTrue(UpdateMenu.rows(state: skipped, timeZone: tokyo).contains(.label("v1.2.0 はスキップしました（いまは v1.1.0）")))

        let none = UpdateSnapshot(build: .release(current), decision: .noStableRelease, lastAttemptAt: nil, failure: nil, rateLimitReset: nil, phase: .idle)
        XCTAssertTrue(UpdateMenu.rows(state: none, timeZone: tokyo).contains(.label("公開中の安定版はありません")))
    }

    func testFailureKeepsSuccessfulDecisionAndShowsOnlySafeFailureText() {
        let snapshot = UpdateSnapshot(
            build: updateCheckBuild(),
            decision: .available(updateCheckVersion("1.2.0")),
            lastAttemptAt: t0,
            failure: .transport,
            rateLimitReset: nil,
            phase: .idle
        )
        let rows = UpdateMenu.rows(state: snapshot, timeZone: tokyo)
        XCTAssertTrue(rows.contains(.action("新しいバージョン v1.2.0 があります", .openRelease(updateCheckVersion("1.2.0")))))
        XCTAssertTrue(rows.contains(.label("確認: 11/14 09:00 に失敗（接続できません）")))
        XCTAssertFalse(rows.map(\.displayText).joined().contains("localizedDescription"))
    }

    func testCheckingOmitsManualActionAndUnsupportedBuildShowsOneDisabledRow() {
        let current = updateCheckVersion("1.1.0")
        let checking = UpdateSnapshot(build: .release(current), decision: nil, lastAttemptAt: nil, failure: nil, rateLimitReset: nil, phase: .checking)
        let checkingRows = UpdateMenu.rows(state: checking, timeZone: tokyo)
        XCTAssertEqual(checkingRows.last, .label("確認しています…"))
        XCTAssertFalse(checkingRows.contains(.action("アップデートを確認", .checkNow)))

        let development = UpdateSnapshot(build: .development, decision: nil, lastAttemptAt: nil, failure: nil, rateLimitReset: nil, phase: .idle)
        XCTAssertEqual(UpdateMenu.rows(state: development, timeZone: tokyo), [.label("アップデート確認: 開発版では行いません")])
        let unknown = UpdateSnapshot(build: .unknown, decision: nil, lastAttemptAt: nil, failure: nil, rateLimitReset: nil, phase: .idle)
        XCTAssertEqual(UpdateMenu.rows(state: unknown, timeZone: tokyo), [.label("アップデート確認: バージョンが不明なため行いません")])
    }

    func testRateLimitFailureFormatsResetInTokyoTime() {
        let reset = Date(timeIntervalSince1970: 1_794_614_400 + 3 * 60 * 60)
        let snapshot = UpdateSnapshot(build: updateCheckBuild(), decision: nil, lastAttemptAt: t0, failure: .rateLimited, rateLimitReset: reset, phase: .idle)
        XCTAssertTrue(UpdateMenu.rows(state: snapshot, timeZone: tokyo).contains(.label("確認: 11/14 09:00 に失敗（回数制限中（12:00 まで））")))
    }

    func testReleaseURLIsConstructedFromValidatedTagAndTokyoDateRollsOver() {
        XCTAssertEqual(
            UpdateMenu.releaseURL(for: updateCheckVersion("1.2.0")).absoluteString,
            "https://github.com/ChihiroNishioka/genie-in-messages/releases/tag/v1.2.0"
        )
        let rolloverDate = Date(timeIntervalSince1970: 1_794_668_699)
        let snapshot = UpdateSnapshot(
            build: .release(updateCheckVersion("1.1.0")),
            decision: .upToDate(updateCheckVersion("1.1.0")),
            lastAttemptAt: rolloverDate,
            failure: nil,
            rateLimitReset: nil,
            phase: .idle
        )
        XCTAssertTrue(UpdateMenu.rows(state: snapshot, timeZone: tokyo).contains(.label("確認: 11/15 00:04")))
        let currentOffset = TimeZone.current.secondsFromGMT(for: rolloverDate)
        let explicitZone = TimeZone(secondsFromGMT: currentOffset == 0 ? 60 * 60 : 0)!
        let expectedTime = currentOffset == 0 ? "11/14 16:04" : "11/14 15:04"
        XCTAssertTrue(UpdateMenu.rows(state: snapshot, timeZone: explicitZone).contains(.label("確認: \(expectedTime)")))
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_794_614_400) }
    private var tokyo: TimeZone { TimeZone(identifier: "Asia/Tokyo")! }
}
