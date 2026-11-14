import Foundation
import XCTest
@testable import GenieCore

final class UpdateCheckerTests: XCTestCase {
    func testFirstTickStartsOneCheckAndSuccessPublishesAvailability() async {
        let fetcher = ScriptedReleaseFetcher([.immediate(updateCheckSuccess("v1.2.0"))])
        let log = RecordingUpdateLog()
        let checker = makeChecker(fetcher: fetcher, log: log)
        await checker.tick()
        await log.waitForEvents(1)
        let snapshot = await checker.snapshot()
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(snapshot.decision, .available(updateCheckVersion("1.2.0")))
        XCTAssertNotNil(snapshot.lastAttemptAt)
    }

    func testDevelopmentAndUnknownBuildNeverCallFetcherEvenForManualRequests() async {
        for build in [UpdateBuild.development, .unknown] {
            let fetcher = ScriptedReleaseFetcher([.immediate(updateCheckSuccess("v1.2.0"))])
            let checker = UpdateChecker(
                clock: MutableUpdateClock(t0), fetcher: fetcher, skipStore: MemoryUpdateSkipStore(),
                build: build, log: RecordingUpdateLog()
            )
            for _ in 0..<4 {
                await checker.tick()
                await checker.requestCheck()
            }
            await checker.tick()
            let snapshot = await checker.snapshot()
            let calls = await fetcher.calls
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(snapshot.phase, .idle)
            let rows = UpdateMenu.rows(state: snapshot, timeZone: tokyo)
            XCTAssertEqual(rows.count, 1)
            XCTAssertFalse(rows.contains { $0.action != nil })
        }
    }

    func testTickReturnsWhileFetchIsBlockedAndManualRequestsDoNotQueue() async {
        let fetcher = ScriptedReleaseFetcher([.gated, .immediate(updateCheckSuccess("v1.3.0"))])
        let log = RecordingUpdateLog()
        let checker = makeChecker(fetcher: fetcher, log: log)
        await checker.tick()
        await fetcher.waitForCalls(1)
        let inFlightSnapshot = await checker.snapshot()
        XCTAssertEqual(inFlightSnapshot.phase, .checking)

        for _ in 0..<3 {
            await checker.requestCheck()
            await checker.tick()
        }
        let inFlightCalls = await fetcher.calls
        XCTAssertEqual(inFlightCalls, 1)
        await fetcher.finishNext(updateCheckSuccess("v1.2.0"))
        await log.waitForEvents(1)
        await checker.tick()
        let finalSnapshot = await checker.snapshot()
        XCTAssertEqual(finalSnapshot.phase, .idle)
        let finalCalls = await fetcher.calls
        XCTAssertEqual(finalCalls, 1)
    }

    func testManualCheckBypassesIntervalAndResetsScheduleFromCompletion() async {
        let fetcher = ScriptedReleaseFetcher([
            .immediate(updateCheckSuccess("v1.2.0")),
            .immediate(updateCheckSuccess("v1.1.0")),
            .immediate(.failure(.http(status: 503), rateLimitReset: nil)),
        ])
        let log = RecordingUpdateLog()
        let clock = MutableUpdateClock(t0)
        let checker = UpdateChecker(clock: clock, fetcher: fetcher, skipStore: MemoryUpdateSkipStore(), build: updateCheckBuild(), log: log)
        await checker.tick()
        await log.waitForEvents(1)
        clock.advance(5 * 60 * 60)
        await checker.requestCheck()
        await checker.tick()
        await log.waitForEvents(2)
        clock.advance(19 * 60 * 60)
        await checker.tick()
        let beforeManualDue = await fetcher.calls
        XCTAssertEqual(beforeManualDue, 2)
        clock.advance(5 * 60 * 60)
        await checker.tick()
        await log.waitForEvents(3)
        let atManualDue = await fetcher.calls
        XCTAssertEqual(atManualDue, 3)
    }

    func testRateLimitBlocksManualRequestUntilResetWithoutCallingFetcher() async {
        let reset = t0.addingTimeInterval(30 * 60 * 60)
        let fetcher = ScriptedReleaseFetcher([
            .immediate(.failure(.rateLimited, rateLimitReset: reset)),
            .immediate(updateCheckSuccess("v1.2.0")),
        ])
        let log = RecordingUpdateLog()
        let clock = MutableUpdateClock(t0)
        let checker = UpdateChecker(clock: clock, fetcher: fetcher, skipStore: MemoryUpdateSkipStore(), build: updateCheckBuild(), log: log)
        await checker.tick()
        await log.waitForEvents(1)
        clock.advance(60 * 60)
        await checker.requestCheck()
        await checker.tick()
        let rateLimitedCalls = await fetcher.calls
        XCTAssertEqual(rateLimitedCalls, 1)
        let rateLimitedSnapshot = await checker.snapshot()
        XCTAssertTrue(UpdateMenu.rows(state: rateLimitedSnapshot, timeZone: tokyo).contains { $0.displayText.contains("回数制限中") })

        clock.advance(29 * 60 * 60)
        await checker.tick()
        await log.waitForEvents(2)
        let resetCalls = await fetcher.calls
        XCTAssertEqual(resetCalls, 2)
    }

    func testFailureKeepsPriorSuccessAndDisplaysTheLatestAttemptError() async {
        let fetcher = ScriptedReleaseFetcher([
            .immediate(updateCheckSuccess("v1.2.0")),
            .immediate(.failure(.transport, rateLimitReset: nil)),
        ])
        let log = RecordingUpdateLog()
        let clock = MutableUpdateClock(t0)
        let checker = UpdateChecker(clock: clock, fetcher: fetcher, skipStore: MemoryUpdateSkipStore(), build: updateCheckBuild(), log: log)
        await checker.tick()
        await log.waitForEvents(1)
        clock.advance(24 * 60 * 60)
        await checker.tick()
        await log.waitForEvents(2)
        let snapshot = await checker.snapshot()
        XCTAssertEqual(snapshot.decision, .available(updateCheckVersion("1.2.0")))
        XCTAssertEqual(snapshot.failure, .transport)
        XCTAssertTrue(UpdateMenu.rows(state: snapshot, timeZone: tokyo).contains { $0.displayText.contains("に失敗（接続できません）") })
    }

    func testSkippingAvailableVersionPersistsOnlyThatVersionWithoutFetching() async {
        let fetcher = ScriptedReleaseFetcher([.immediate(updateCheckSuccess("v1.2.0"))])
        let store = MemoryUpdateSkipStore()
        let log = RecordingUpdateLog()
        let checker = UpdateChecker(clock: MutableUpdateClock(t0), fetcher: fetcher, skipStore: store, build: updateCheckBuild(), log: log)
        await checker.tick()
        await log.waitForEvents(1)
        await checker.skip(updateCheckVersion("1.2.0"))
        let writes = await store.writes
        XCTAssertEqual(writes, ["1.2.0"])
        let snapshot = await checker.snapshot()
        XCTAssertEqual(snapshot.decision, .skipped(updateCheckVersion("1.2.0")))
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 1)
    }

    private func makeChecker(fetcher: ScriptedReleaseFetcher, log: RecordingUpdateLog) -> UpdateChecker {
        UpdateChecker(clock: MutableUpdateClock(t0), fetcher: fetcher, skipStore: MemoryUpdateSkipStore(), build: updateCheckBuild(), log: log)
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_794_614_400) }
    private var tokyo: TimeZone { TimeZone(identifier: "Asia/Tokyo")! }
}
