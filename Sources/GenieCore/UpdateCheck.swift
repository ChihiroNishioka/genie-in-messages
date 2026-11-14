import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    package let major: Int
    package let minor: Int
    package let patch: Int

    package init?(tag: String) {
        guard tag.hasPrefix("v"), let parsed = Self.parse(String(tag.dropFirst()), allowLeadingZero: false) else {
            return nil
        }
        self = parsed
    }

    package init?(raw: String) {
        guard let parsed = Self.parse(raw, allowLeadingZero: true) else { return nil }
        self = parsed
    }

    package var description: String { "\(major).\(minor).\(patch)" }
    package var tag: String { "v\(description)" }

    package static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func parse(_ text: String, allowLeadingZero: Bool) -> ReleaseVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let values = parts.map { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            if !allowLeadingZero, part.count > 1, part.first == "0" { return nil }
            return Int(part)
        }
        guard values.allSatisfy({ $0 != nil }),
              let major = values[0], let minor = values[1], let patch = values[2] else {
            return nil
        }
        return ReleaseVersion(major: major, minor: minor, patch: patch)
    }

    private init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

package enum UpdateBuild: Sendable, Equatable {
    case release(ReleaseVersion)
    case development
    case unknown
}

package struct ReleaseEntry: Sendable, Equatable {
    package let tag: String
    package let draft: Bool
    package let prerelease: Bool

    package init(tag: String, draft: Bool, prerelease: Bool) {
        self.tag = tag
        self.draft = draft
        self.prerelease = prerelease
    }
}

package enum ReleaseSelection {
    package static func latestStable(in entries: [ReleaseEntry]) -> ReleaseVersion? {
        entries.lazy
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { ReleaseVersion(tag: $0.tag) }
            .max()
    }
}

package enum UpdateDecision: Sendable, Equatable {
    case noStableRelease
    case upToDate(ReleaseVersion)
    case available(ReleaseVersion)
    case skipped(ReleaseVersion)
}

package enum UpdatePolicy {
    package static func decide(
        current: ReleaseVersion,
        latest: ReleaseVersion?,
        skipped: ReleaseVersion?
    ) -> UpdateDecision {
        guard let latest else { return .noStableRelease }
        guard latest > current else { return .upToDate(current) }
        if let skipped, latest <= skipped { return .skipped(latest) }
        return .available(latest)
    }
}

package enum UpdatePreferences {
    package static func skipped(from raw: Any?) -> ReleaseVersion? {
        guard let text = raw as? String,
              let version = ReleaseVersion(raw: text),
              Self.raw(for: version) == text else { return nil }
        return version
    }

    package static func raw(for version: ReleaseVersion) -> String { version.description }
}

package enum UpdateCheckFailure: Sendable, Equatable {
    case transport
    case rateLimited
    case http(status: Int)
    case decode

    package var logCode: String {
        switch self {
        case .transport: "update_check_transport"
        case .rateLimited: "update_check_rate_limited"
        case .http: "update_check_http"
        case .decode: "update_check_decode"
        }
    }

    package var statusCode: Int? {
        guard case .http(let status) = self else { return nil }
        return status
    }

    package var menuText: String {
        switch self {
        case .transport: "接続できません"
        case .rateLimited: "回数制限中"
        case .http(let status): "応答が不正です（HTTP \(status)）"
        case .decode: "応答を読めません"
        }
    }
}

package enum ReleaseFetchResult: Sendable, Equatable {
    case success([ReleaseEntry])
    case failure(UpdateCheckFailure, rateLimitReset: Date?)
}

package protocol ReleaseFetching: Sendable {
    func fetch() async -> ReleaseFetchResult
}

package protocol SkipStore: Sendable {
    func read() async -> Any?
    func write(_ raw: String) async
}

package actor UserDefaultsSkipStore: SkipStore {
    private let defaults: UserDefaults
    private let key = "GenieUpdateSkippedVersion"

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func read() async -> Any? { defaults.object(forKey: key) }

    package func write(_ raw: String) async {
        defaults.set(raw, forKey: key)
    }
}

package enum UpdateAttempt: Sendable, Equatable {
    case success
    case failure(UpdateCheckFailure, rateLimitReset: Date?)
}

package struct UpdateSchedule: Sendable, Equatable {
    private(set) var completedAt: Date?
    private(set) var attempt: UpdateAttempt?
    private(set) var nextDue: Date?
    private(set) var rateLimitReset: Date?

    package init() {}

    package func isDue(now: Date, isInFlight: Bool = false) -> Bool {
        !isInFlight && (nextDue == nil || now >= nextDue!)
    }

    package mutating func record(_ attempt: UpdateAttempt, completedAt: Date) {
        self.attempt = attempt
        self.completedAt = completedAt
        switch attempt {
        case .success:
            rateLimitReset = nil
            nextDue = completedAt.addingTimeInterval(24 * 60 * 60)
        case .failure(let failure, let reset):
            if failure == .rateLimited {
                rateLimitReset = reset
                let oneHour = completedAt.addingTimeInterval(60 * 60)
                nextDue = max(oneHour, reset ?? oneHour)
            } else {
                rateLimitReset = nil
                nextDue = completedAt.addingTimeInterval(60 * 60)
            }
        }
    }

    package func isRateLimited(now: Date) -> Bool {
        guard let rateLimitReset else { return false }
        return now < rateLimitReset
    }
}

package struct UpdateLogGate: Sendable {
    private var lastCode: String?

    package init() {}

    package mutating func shouldLog(_ code: String) -> Bool {
        guard code != lastCode else { return false }
        lastCode = code
        return true
    }
}

package enum UpdateCheckPhase: Sendable, Equatable {
    case idle
    case checking
}

package struct UpdateSnapshot: Sendable, Equatable {
    package let build: UpdateBuild
    package let decision: UpdateDecision?
    package let lastAttemptAt: Date?
    package let failure: UpdateCheckFailure?
    package let rateLimitReset: Date?
    package let phase: UpdateCheckPhase

    package init(
        build: UpdateBuild,
        decision: UpdateDecision?,
        lastAttemptAt: Date?,
        failure: UpdateCheckFailure?,
        rateLimitReset: Date?,
        phase: UpdateCheckPhase
    ) {
        self.build = build
        self.decision = decision
        self.lastAttemptAt = lastAttemptAt
        self.failure = failure
        self.rateLimitReset = rateLimitReset
        self.phase = phase
    }
}

package enum UpdateAction: Sendable, Equatable {
    case openRelease(ReleaseVersion)
    case skip(ReleaseVersion)
    case checkNow
}

package enum UpdateMenuRow: Sendable, Equatable {
    case label(String)
    case action(String, UpdateAction)
}

package enum UpdateMenu {
    package static func rows(state: UpdateSnapshot, timeZone: TimeZone) -> [UpdateMenuRow] {
        switch state.build {
        case .development:
            return [.label("アップデート確認: 開発版では行いません")]
        case .unknown:
            return [.label("アップデート確認: バージョンが不明なため行いません")]
        case .release(let current):
            var rows: [UpdateMenuRow] = []
            if let decision = state.decision {
                switch decision {
                case .noStableRelease:
                    rows.append(.label("公開中の安定版はありません"))
                case .upToDate(let version):
                    rows.append(.label("最新です（v\(version)）"))
                case .available(let version):
                    rows.append(.action("新しいバージョン v\(version) があります", .openRelease(version)))
                    rows.append(.action("このバージョンはスキップ", .skip(version)))
                case .skipped(let version):
                    rows.append(.label("v\(version) はスキップしました（いまは v\(current)）"))
                }
            }
            if let lastAttemptAt = state.lastAttemptAt {
                let time = format(lastAttemptAt, pattern: "M/d HH:mm", timeZone: timeZone)
                if let failure = state.failure {
                    var message = failure.menuText
                    if failure == .rateLimited, let reset = state.rateLimitReset {
                        message = "回数制限中（\(format(reset, pattern: "HH:mm", timeZone: timeZone)) まで）"
                    }
                    rows.append(.label("確認: \(time) に失敗（\(message)）"))
                } else {
                    rows.append(.label("確認: \(time)"))
                }
            }
            switch state.phase {
            case .idle:
                rows.append(.action("アップデートを確認", .checkNow))
            case .checking:
                rows.append(.label("確認しています…"))
            }
            return rows
        }
    }

    package static func releaseURL(for version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/ChihiroNishioka/genie-in-messages/releases/tag/\(version.tag)")!
    }

    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

package struct UpdateCheckLogEvent: Sendable, Equatable {
    package let result: String
    package let current: String?
    package let latest: String?
    package let code: String?
    package let status: Int?

    package var line: String {
        "event=update_check result=\(result) current=\(current ?? "-") latest=\(latest ?? "-") code=\(code ?? "-") status=\(status.map { String($0) } ?? "-")"
    }
}

package protocol UpdateCheckLogging: Sendable {
    func record(_ event: UpdateCheckLogEvent) async
}

package struct GenieUpdateCheckLogger: UpdateCheckLogging {
    private let log: any GenieLog

    package init(log: any GenieLog) { self.log = log }

    package func record(_ event: UpdateCheckLogEvent) async {
        log.record(
            level: event.code == nil ? .info : .warning,
            code: event.code ?? "update_check",
            chatID: nil,
            guid: nil,
            rowid: nil,
            detail: event.line
        )
    }
}

package actor UpdateChecker {
    private let clock: any GenieClock
    private let fetcher: any ReleaseFetching
    private let skipStore: any SkipStore
    private let build: UpdateBuild
    private let log: any UpdateCheckLogging
    private var schedule = UpdateSchedule()
    private var phase: UpdateCheckPhase = .idle
    private var decision: UpdateDecision?
    private var latest: ReleaseVersion?
    private var skipped: ReleaseVersion?
    private var failure: UpdateCheckFailure?
    private var rateLimitReset: Date?
    private var lastAttemptAt: Date?
    private var manualRequested = false
    private var loadedSkip = false
    private var logGate = UpdateLogGate()
    private var loggedUnsupportedBuild = false

    package init(
        clock: any GenieClock,
        fetcher: any ReleaseFetching,
        skipStore: any SkipStore,
        build: UpdateBuild,
        log: any UpdateCheckLogging
    ) {
        self.clock = clock
        self.fetcher = fetcher
        self.skipStore = skipStore
        self.build = build
        self.log = log
    }

    package func tick() async {
        guard case .release(let current) = build else {
            if !loggedUnsupportedBuild {
                loggedUnsupportedBuild = true
                await emit(result: "skipped_dev", current: nil, latest: nil, code: nil, status: nil, gateKey: "skipped_dev")
            }
            return
        }

        if !loadedSkip {
            skipped = UpdatePreferences.skipped(from: await skipStore.read())
            loadedSkip = true
            if let latest {
                decision = UpdatePolicy.decide(current: current, latest: latest, skipped: skipped)
            }
        }

        let now = clock.now()
        let manual = manualRequested
        manualRequested = false
        guard phase == .idle else { return }
        if manual, schedule.isRateLimited(now: now) { return }
        guard manual || schedule.isDue(now: now) else { return }

        phase = .checking
        let fetcher = self.fetcher
        Task { [weak self] in
            let result = await fetcher.fetch()
            await self?.finish(result)
        }
    }

    package func requestCheck() {
        guard case .release = build, phase == .idle else { return }
        manualRequested = true
    }

    package func skip(_ version: ReleaseVersion) async {
        guard case .release(let current) = build,
              case .available(let available)? = decision,
              available == version else { return }
        skipped = version
        await skipStore.write(UpdatePreferences.raw(for: version))
        decision = UpdatePolicy.decide(current: current, latest: latest, skipped: skipped)
        let result = resultName(for: decision)
        await emit(result: result, current: current, latest: latest, code: nil, status: nil, gateKey: result)
    }

    package func snapshot() -> UpdateSnapshot {
        UpdateSnapshot(
            build: build,
            decision: decision,
            lastAttemptAt: lastAttemptAt,
            failure: failure,
            rateLimitReset: rateLimitReset,
            phase: phase
        )
    }

    private func finish(_ result: ReleaseFetchResult) async {
        let completedAt = clock.now()
        lastAttemptAt = completedAt
        phase = .idle

        switch result {
        case .success(let entries):
            latest = ReleaseSelection.latestStable(in: entries)
            failure = nil
            rateLimitReset = nil
            schedule.record(.success, completedAt: completedAt)
            if case .release(let current) = build {
                decision = UpdatePolicy.decide(current: current, latest: latest, skipped: skipped)
            }
            let name = resultName(for: decision)
            await emit(result: name, current: currentVersion, latest: latest, code: nil, status: nil, gateKey: name)
        case .failure(let failure, let reset):
            self.failure = failure
            rateLimitReset = reset
            schedule.record(.failure(failure, rateLimitReset: reset), completedAt: completedAt)
            await emit(
                result: "failed",
                current: currentVersion,
                latest: latest,
                code: failure.logCode,
                status: failure.statusCode,
                gateKey: failure.logCode
            )
        }
    }

    private var currentVersion: ReleaseVersion? {
        guard case .release(let current) = build else { return nil }
        return current
    }

    private func resultName(for decision: UpdateDecision?) -> String {
        switch decision {
        case .available: "available"
        case .upToDate: "up_to_date"
        case .skipped: "skipped"
        case .noStableRelease, nil: "none"
        }
    }

    private func emit(result: String, current: ReleaseVersion?, latest: ReleaseVersion?, code: String?, status: Int?, gateKey: String) async {
        guard logGate.shouldLog(gateKey) else { return }
        await log.record(UpdateCheckLogEvent(
            result: result,
            current: current?.description,
            latest: latest?.description,
            code: code,
            status: status
        ))
    }
}
