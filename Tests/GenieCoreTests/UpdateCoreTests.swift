import Foundation
import XCTest
@testable import GenieCore

final class UpdateCoreTests: XCTestCase {
    func testReleaseVersionParsesOnlyCanonicalTagsAndRejectsOverflow() {
        XCTAssertEqual(ReleaseVersion(tag: "v1.2.0")?.description, "1.2.0")
        XCTAssertEqual(ReleaseVersion(tag: "v0.0.1")?.description, "0.0.1")
        XCTAssertEqual(ReleaseVersion(tag: "v10.20.30")?.description, "10.20.30")

        for invalid in [
            "1.2.0", "v1.2", "v1.2.0-rc1", "v1.2.0+b", "v01.2.0", "V1.2.0",
            " v1.2.0", "v1.2.0 ", "v1.2.1-rc1", "macmini-20261112", "v99999999999999999999.0.0",
        ] {
            XCTAssertNil(ReleaseVersion(tag: invalid), invalid)
        }
    }

    func testReleaseVersionComparesComponentsNumerically() {
        XCTAssertGreaterThan(tryVersion("1.10.0"), tryVersion("1.9.0"))
        XCTAssertGreaterThan(tryVersion("2.0.0"), tryVersion("1.99.99"))
        XCTAssertEqual(tryVersion("1.2.0"), tryVersion("1.2.0"))
    }

    func testUpdateBuildParsesBundleComponentsWithoutChangingMenuText() {
        XCTAssertEqual(
            AppVersion.updateBuild(info: ["GenieReleaseVersion": "1.01.0", "GenieGitCommit": "fe7cf02"]),
            .release(tryVersion("1.1.0"))
        )
        XCTAssertEqual(
            AppVersion.menuLine(info: ["GenieReleaseVersion": "1.01.0", "GenieGitCommit": "fe7cf02"]),
            "バージョン: v1.01.0（fe7cf02）"
        )
        XCTAssertEqual(
            AppVersion.updateBuild(info: ["GenieReleaseVersion": "", "GenieGitCommit": "abc1234"]),
            .development
        )
        XCTAssertEqual(AppVersion.updateBuild(info: nil), .unknown)
        XCTAssertEqual(
            AppVersion.updateBuild(info: ["GenieReleaseVersion": "1.0.99999999999999999999", "GenieGitCommit": "fe7cf02"]),
            .unknown
        )
        XCTAssertEqual(
            AppVersion.updateBuild(info: ["GenieReleaseVersion": "1.0.0", "GenieGitCommit": "ABC1234"]),
            .unknown
        )
    }

    func testLatestStableUsesHighestVersionAndIgnoresUnstableOrMalformedTags() {
        let entries = [
            ReleaseEntry(tag: "v1.9.0", draft: false, prerelease: false),
            ReleaseEntry(tag: "v1.10.0", draft: false, prerelease: false),
            ReleaseEntry(tag: "v1.3.0", draft: false, prerelease: true),
            ReleaseEntry(tag: "v1.2.5", draft: true, prerelease: false),
            ReleaseEntry(tag: "macmini-20261112", draft: false, prerelease: false),
            ReleaseEntry(tag: "v1.11.0-rc1", draft: false, prerelease: false),
        ]
        XCTAssertEqual(ReleaseSelection.latestStable(in: entries), tryVersion("1.10.0"))
        XCTAssertNil(ReleaseSelection.latestStable(in: []))
        XCTAssertNil(ReleaseSelection.latestStable(in: [
            ReleaseEntry(tag: "v1.3.0", draft: false, prerelease: true),
            ReleaseEntry(tag: "macmini-20261112", draft: false, prerelease: false),
        ]))
    }

    func testUpdatePolicyComparesCurrentLatestAndSkippedVersions() {
        XCTAssertEqual(UpdatePolicy.decide(current: tryVersion("1.1.0"), latest: tryVersion("1.2.0"), skipped: nil), .available(tryVersion("1.2.0")))
        XCTAssertEqual(UpdatePolicy.decide(current: tryVersion("1.1.0"), latest: tryVersion("1.1.0"), skipped: nil), .upToDate(tryVersion("1.1.0")))
        XCTAssertEqual(UpdatePolicy.decide(current: tryVersion("1.2.0"), latest: tryVersion("1.1.0"), skipped: nil), .upToDate(tryVersion("1.2.0")))
        XCTAssertEqual(UpdatePolicy.decide(current: tryVersion("1.1.0"), latest: tryVersion("1.2.0"), skipped: tryVersion("1.2.0")), .skipped(tryVersion("1.2.0")))
        XCTAssertEqual(UpdatePolicy.decide(current: tryVersion("1.1.0"), latest: tryVersion("1.3.0"), skipped: tryVersion("1.2.0")), .available(tryVersion("1.3.0")))
        XCTAssertEqual(UpdatePolicy.decide(current: tryVersion("1.1.0"), latest: nil, skipped: nil), .noStableRelease)
    }

    func testUpdatePreferencesAcceptOnlyCanonicalStoredReleaseStrings() {
        XCTAssertEqual(UpdatePreferences.skipped(from: "1.2.0"), tryVersion("1.2.0"))
        for invalid: Any? in ["v1.2.0", "x", 42, nil] {
            XCTAssertNil(UpdatePreferences.skipped(from: invalid))
        }
        XCTAssertEqual(UpdatePreferences.raw(for: tryVersion("1.2.0")), "1.2.0")
    }

    func testUpdateScheduleStartsImmediatelyAndSuccessWaitsTwentyFourHours() {
        var schedule = UpdateSchedule()
        XCTAssertTrue(schedule.isDue(now: t0))
        schedule.record(.success, completedAt: t0)
        XCTAssertFalse(schedule.isDue(now: t0.addingTimeInterval(24 * 60 * 60 - 1)))
        XCTAssertTrue(schedule.isDue(now: t0.addingTimeInterval(24 * 60 * 60)))
    }

    func testUpdateScheduleUsesOneHourAfterOrdinaryFailure() {
        var schedule = UpdateSchedule()
        schedule.record(.failure(.transport, rateLimitReset: nil), completedAt: t0)
        XCTAssertFalse(schedule.isDue(now: t0.addingTimeInterval(60 * 60 - 1)))
        XCTAssertTrue(schedule.isDue(now: t0.addingTimeInterval(60 * 60)))
        schedule.record(.failure(.rateLimited, rateLimitReset: nil), completedAt: t0)
        XCTAssertTrue(schedule.isDue(now: t0.addingTimeInterval(60 * 60)))
    }

    func testUpdateScheduleWaitsForRateLimitResetEvenBeyondOneDay() {
        var schedule = UpdateSchedule()
        schedule.record(.failure(.rateLimited, rateLimitReset: t0.addingTimeInterval(3 * 60 * 60)), completedAt: t0)
        XCTAssertFalse(schedule.isDue(now: t0.addingTimeInterval(3 * 60 * 60 - 1)))
        XCTAssertTrue(schedule.isDue(now: t0.addingTimeInterval(3 * 60 * 60)))

        schedule.record(.failure(.rateLimited, rateLimitReset: t0.addingTimeInterval(10 * 60)), completedAt: t0)
        XCTAssertTrue(schedule.isDue(now: t0.addingTimeInterval(60 * 60)))
        schedule.record(.failure(.rateLimited, rateLimitReset: t0.addingTimeInterval(30 * 60 * 60)), completedAt: t0)
        XCTAssertFalse(schedule.isDue(now: t0.addingTimeInterval(24 * 60 * 60)))
        XCTAssertTrue(schedule.isDue(now: t0.addingTimeInterval(30 * 60 * 60)))
    }

    func testManualSuccessfulAttemptStartsAnewTwentyFourHourInterval() {
        var schedule = UpdateSchedule()
        schedule.record(.success, completedAt: t0)
        schedule.record(.success, completedAt: t0.addingTimeInterval(5 * 60 * 60))
        XCTAssertFalse(schedule.isDue(now: t0.addingTimeInterval(24 * 60 * 60)))
        XCTAssertFalse(schedule.isDue(now: t0.addingTimeInterval(29 * 60 * 60 - 1)))
        XCTAssertTrue(schedule.isDue(now: t0.addingTimeInterval(29 * 60 * 60)))
    }

    func testUpdateScheduleDoesNotStartWhileAnAttemptIsInFlight() {
        var schedule = UpdateSchedule()
        XCTAssertFalse(schedule.isDue(now: t0, isInFlight: true))
    }

    func testUpdateLogGateLogsRepeatedResultCodeOnceAndLogsChangesAndRecovery() {
        var gate = UpdateLogGate()
        XCTAssertTrue(gate.shouldLog("update_check_transport"))
        XCTAssertFalse(gate.shouldLog("update_check_transport"))
        XCTAssertTrue(gate.shouldLog("update_check_rate_limited"))
        XCTAssertTrue(gate.shouldLog("available"))
        XCTAssertFalse(gate.shouldLog("available"))
        XCTAssertTrue(gate.shouldLog("update_check_transport"))
    }

    private func tryVersion(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> ReleaseVersion {
        guard let version = ReleaseVersion(raw: raw) else {
            XCTFail("Expected numeric release version", file: file, line: line)
            return ReleaseVersion(raw: "0.0.0")!
        }
        return version
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_794_614_400) }
}
