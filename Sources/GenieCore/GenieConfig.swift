import Foundation

package struct GenieConfig: Equatable, Sendable {
    package var webhookURL: String
    package var replyFetchURL: String
    package var marker: String
    package var imsgExecutable: String
    package var rateLimitCount: Int
    package var rateLimitWindowSeconds: Double
    package var webhookMaxAttempts: Int
    package var webhookInitialBackoffSeconds: Double
    package var webhookMaxBackoffSeconds: Double
    package var replyPollIntervalSeconds: Double
    package var holdRetryIntervalSeconds: Double
    package var fingerprintWindowSeconds: Double
    package var chatsLimit: Int
    package var logFile: String?
    package var routeTTLSeconds: Double
    package var sendTimeoutSeconds: Double
    package var chatsTimeoutSeconds: Double
    package var replyPageLimit: Int
    package var notionDataSourceID: String

    package static let productDefaults = GenieConfig(
        webhookURL: "",
        replyFetchURL: "",
        marker: "\u{1F5E8}\u{FE0F}\u{1F9DE}\u{200D}\u{2642}\u{FE0F}",
        imsgExecutable: "/opt/homebrew/opt/imsg/libexec/imsg",
        rateLimitCount: 5,
        rateLimitWindowSeconds: 60,
        webhookMaxAttempts: 5,
        webhookInitialBackoffSeconds: 1,
        webhookMaxBackoffSeconds: 60,
        replyPollIntervalSeconds: 10,
        holdRetryIntervalSeconds: 15,
        fingerprintWindowSeconds: 120,
        chatsLimit: 100,
        logFile: nil,
        routeTTLSeconds: 604_800,
        sendTimeoutSeconds: 150,
        chatsTimeoutSeconds: 30,
        replyPageLimit: 100,
        notionDataSourceID: ""
    )

    func sanitized() -> GenieConfig {
        var copy = self
        if copy.imsgExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.imsgExecutable = GenieConfig.productDefaults.imsgExecutable
        }
        copy.rateLimitCount = max(1, copy.rateLimitCount)
        copy.rateLimitWindowSeconds = max(1, copy.rateLimitWindowSeconds)
        copy.webhookMaxAttempts = max(1, copy.webhookMaxAttempts)
        copy.webhookInitialBackoffSeconds = max(0, copy.webhookInitialBackoffSeconds)
        copy.webhookMaxBackoffSeconds = max(copy.webhookInitialBackoffSeconds, copy.webhookMaxBackoffSeconds)
        copy.replyPollIntervalSeconds = max(1, copy.replyPollIntervalSeconds)
        copy.holdRetryIntervalSeconds = max(1, copy.holdRetryIntervalSeconds)
        copy.fingerprintWindowSeconds = max(1, copy.fingerprintWindowSeconds)
        copy.chatsLimit = max(1, copy.chatsLimit)
        copy.routeTTLSeconds = max(60, copy.routeTTLSeconds)
        copy.sendTimeoutSeconds = max(1, copy.sendTimeoutSeconds)
        copy.chatsTimeoutSeconds = max(1, copy.chatsTimeoutSeconds)
        copy.replyPageLimit = max(1, copy.replyPageLimit)
        copy.notionDataSourceID = copy.notionDataSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

extension GenieConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case webhookURL = "webhook_url"
        case replyFetchURL = "reply_fetch_url"
        case marker
        case imsgExecutable = "imsg_executable"
        case rateLimitCount = "rate_limit_count"
        case rateLimitWindowSeconds = "rate_limit_window_seconds"
        case webhookMaxAttempts = "webhook_max_attempts"
        case webhookInitialBackoffSeconds = "webhook_initial_backoff_seconds"
        case webhookMaxBackoffSeconds = "webhook_max_backoff_seconds"
        case replyPollIntervalSeconds = "reply_poll_interval_seconds"
        case holdRetryIntervalSeconds = "hold_retry_interval_seconds"
        case fingerprintWindowSeconds = "fingerprint_window_seconds"
        case chatsLimit = "chats_limit"
        case logFile = "log_file"
        case routeTTLSeconds = "route_ttl_seconds"
        case sendTimeoutSeconds = "send_timeout_seconds"
        case chatsTimeoutSeconds = "chats_timeout_seconds"
        case replyPageLimit = "reply_page_limit"
        case notionDataSourceID = "notion_data_source_id"
    }

    package init(from decoder: Decoder) throws {
        let defaults = GenieConfig.productDefaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL) ?? defaults.webhookURL
        replyFetchURL = try c.decodeIfPresent(String.self, forKey: .replyFetchURL) ?? defaults.replyFetchURL
        marker = try c.decodeIfPresent(String.self, forKey: .marker) ?? defaults.marker
        imsgExecutable = try c.decodeIfPresent(String.self, forKey: .imsgExecutable) ?? defaults.imsgExecutable
        rateLimitCount = try c.decodeIfPresent(Int.self, forKey: .rateLimitCount) ?? defaults.rateLimitCount
        rateLimitWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .rateLimitWindowSeconds) ?? defaults.rateLimitWindowSeconds
        webhookMaxAttempts = try c.decodeIfPresent(Int.self, forKey: .webhookMaxAttempts) ?? defaults.webhookMaxAttempts
        webhookInitialBackoffSeconds = try c.decodeIfPresent(Double.self, forKey: .webhookInitialBackoffSeconds) ?? defaults.webhookInitialBackoffSeconds
        webhookMaxBackoffSeconds = try c.decodeIfPresent(Double.self, forKey: .webhookMaxBackoffSeconds) ?? defaults.webhookMaxBackoffSeconds
        replyPollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .replyPollIntervalSeconds) ?? defaults.replyPollIntervalSeconds
        holdRetryIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .holdRetryIntervalSeconds) ?? defaults.holdRetryIntervalSeconds
        fingerprintWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .fingerprintWindowSeconds) ?? defaults.fingerprintWindowSeconds
        chatsLimit = try c.decodeIfPresent(Int.self, forKey: .chatsLimit) ?? defaults.chatsLimit
        logFile = try c.decodeIfPresent(String.self, forKey: .logFile)
        routeTTLSeconds = try c.decodeIfPresent(Double.self, forKey: .routeTTLSeconds) ?? defaults.routeTTLSeconds
        sendTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .sendTimeoutSeconds) ?? defaults.sendTimeoutSeconds
        chatsTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .chatsTimeoutSeconds) ?? defaults.chatsTimeoutSeconds
        replyPageLimit = try c.decodeIfPresent(Int.self, forKey: .replyPageLimit) ?? defaults.replyPageLimit
        notionDataSourceID = try c.decodeIfPresent(String.self, forKey: .notionDataSourceID) ?? defaults.notionDataSourceID
        self = sanitized()
    }
}

package protocol ConfigProviding: Sendable {
    func load() throws -> GenieConfig
}

struct StaticConfig: ConfigProviding, Sendable {
    var config: GenieConfig
    func load() throws -> GenieConfig { config.sanitized() }
}

package enum ConfigLoader {
    package static func load(from url: URL) throws -> GenieConfig {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(GenieConfig.self, from: data).sanitized()
    }

    static func write(_ config: GenieConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config.sanitized())
        try data.write(to: url, options: .atomic)
        try FilePermissions.set(url, mode: 0o600)
    }
}
