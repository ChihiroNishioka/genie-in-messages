import Foundation

package struct GenieConfig: Equatable, Sendable {
    package var groupChatGUIDs: [String] = []
    package var replyMarker: String = "\u{1F9DE}\u{200D}\u{2642}\u{FE0F}"
    package var replyMarkerInvalid: Bool = false
    package var jobWebhookURL: String = ""
    package var jobChatIDs: [Int64] = []
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
    /// 自分の webhook 表示名。空なら `me`。
    package var selfSenderName: String
    /// ハンドルから表示名。反応の可否には使わない。
    package var senderNames: [String: String]
    /// 自分宛てとして扱う chat.ROWID。無くても判定できる。
    package var selfChatIDs: [Int64]
    /// 比較キーから表示名。設定ファイルには書かない。
    package var senderNameKeys: [String: String] = [:]

    package static let productDefaults = GenieConfig(
        jobWebhookURL: "",
        jobChatIDs: [],
        webhookURL: "",
        replyFetchURL: "",
        marker: "\u{1F9DE}\u{200D}\u{2642}\u{FE0F}",
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
        notionDataSourceID: "",
        selfSenderName: "me",
        senderNames: [:],
        selfChatIDs: []
    )

    func sanitized() -> GenieConfig {
        var copy = self
        var seenGroupGUIDs: Set<String> = []
        copy.groupChatGUIDs = copy.groupChatGUIDs.compactMap { raw in
            let guid = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !guid.isEmpty && seenGroupGUIDs.insert(guid).inserted ? guid : nil
        }
        let candidate = Self.trimMarkerWhitespace(TextNormalizer.nfc(copy.replyMarker))
        if Self.isValidReplyMarker(candidate) {
            copy.replyMarker = candidate
        } else {
            copy.replyMarker = ReplyComposer.markerText
            copy.replyMarkerInvalid = true
        }
        copy.jobWebhookURL = copy.jobWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var seenJobChatIDs: Set<Int64> = []
        copy.jobChatIDs = copy.jobChatIDs.filter { seenJobChatIDs.insert($0).inserted }
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
        let selfName = copy.selfSenderName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.selfSenderName = TextNormalizer.isBlank(selfName) ? "me" : selfName
        copy.senderNameKeys = Self.indexNames(copy.senderNames)
        var seenChatIDs: Set<Int64> = []
        copy.selfChatIDs = copy.selfChatIDs.filter { seenChatIDs.insert($0).inserted }
        return copy
    }

    private static func trimMarkerWhitespace(_ marker: String) -> String {
        let scalars = marker.unicodeScalars
        let isSpace: (Unicode.Scalar) -> Bool = {
            CharacterSet.whitespacesAndNewlines.contains($0) && !$0.properties.isDefaultIgnorableCodePoint
        }
        let leading = scalars.drop(while: isSpace)
        let trimmed = leading.reversed().drop(while: isSpace).reversed()
        return String(String.UnicodeScalarView(trimmed))
    }

    private static func isValidReplyMarker(_ marker: String) -> Bool {
        guard !TextNormalizer.isBlank(marker),
              let first = marker.unicodeScalars.first, !TextNormalizer.isInvisible(first),
              !marker.unicodeScalars.contains(where: { $0.value == 0x1FA94 }),
              !marker.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
              }),
              marker.count <= 8, marker.unicodeScalars.count <= 32 else { return false }
        return true
    }

    /// 空の表示名と比較できないハンドルは落とす。同じキーは、ハンドル文字列の順で先の名前を残す。
    private static func indexNames(_ names: [String: String]) -> [String: String] {
        var indexed: [String: String] = [:]
        for handle in names.keys.sorted() {
            let name = names[handle]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !TextNormalizer.isBlank(name) else { continue }
            guard let key = SenderHandle.normalize(handle) else { continue }
            if indexed[key] == nil {
                indexed[key] = name
            }
        }
        return indexed
    }

    func displayName(matching handle: String) -> String? {
        guard let key = SenderHandle.normalize(handle) else { return nil }
        return senderNameKeys[key]
    }
}

extension GenieConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case groupChatGUIDs = "group_chat_guids"
        case replyMarker = "reply_marker"
        case jobWebhookURL = "job_webhook_url"
        case jobChatIDs = "job_chat_ids"
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
        case selfSenderName = "self_sender_name"
        case senderNames = "sender_names"
        case selfChatIDs = "self_chat_ids"
    }

    package init(from decoder: Decoder) throws {
        let defaults = GenieConfig.productDefaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupChatGUIDs = try c.decodeIfPresent([String].self, forKey: .groupChatGUIDs) ?? []
        replyMarker = try c.decodeIfPresent(String.self, forKey: .replyMarker) ?? ReplyComposer.markerText
        replyMarkerInvalid = false
        jobWebhookURL = try c.decodeIfPresent(String.self, forKey: .jobWebhookURL) ?? defaults.jobWebhookURL
        jobChatIDs = try Self.decodeJobChatIDs(c)
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
        selfSenderName = try c.decodeIfPresent(String.self, forKey: .selfSenderName) ?? defaults.selfSenderName
        senderNames = try Self.decodeSenderNames(c)
        selfChatIDs = try Self.decodeSelfChatIDs(c)
        senderNameKeys = [:]
        self = sanitized()
    }

    /// キーが無い、または null なら空。反応の可否には使わない。
    private static func decodeSenderNames(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [String: String] {
        guard container.contains(.senderNames) else { return [:] }
        if try container.decodeNil(forKey: .senderNames) { return [:] }
        return try container.decode([String: String].self, forKey: .senderNames)
    }

    private static func decodeJobChatIDs(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [Int64] {
        try container.decodeIfPresent([Int64].self, forKey: .jobChatIDs) ?? []
    }

    /// キーが無い、または null なら空。反応の初期状態はこれ無しでも動く。
    private static func decodeSelfChatIDs(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [Int64] {
        guard container.contains(.selfChatIDs) else { return [] }
        if try container.decodeNil(forKey: .selfChatIDs) { return [] }
        return try container.decode([Int64].self, forKey: .selfChatIDs)
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
