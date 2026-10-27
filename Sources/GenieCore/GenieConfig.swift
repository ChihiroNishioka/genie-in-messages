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
    /// 自分の webhook 表示名。空なら `me`。
    package var selfSenderName: String
    /// チャットごとの、自分以外の許可送信者。
    package var allowedSenders: [ChatSenders]
    /// 読み込んだ印を製品既定へ戻した。設定ファイルには書かない。
    package var markerWasReplaced = false

    package static let productDefaults = GenieConfig(
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
        allowedSenders: []
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
        let selfName = copy.selfSenderName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.selfSenderName = TextNormalizer.isBlank(selfName) ? "me" : selfName
        copy.allowedSenders = Self.collapseSenders(copy.allowedSenders)
        let resolved = ReplyComposer.resolveMarker(copy.marker)
        if resolved.replaced {
            copy.marker = resolved.text
            copy.markerWasReplaced = true
        }
        return copy
    }

    /// 同じチャットの同じハンドルは先の表示名を残す。比較できないハンドルは落とす。
    private static func collapseSenders(_ lists: [ChatSenders]) -> [ChatSenders] {
        var order: [Int64] = []
        var grouped: [Int64: [AllowedSender]] = [:]
        var seen: [Int64: Set<String>] = [:]
        for list in lists {
            if grouped[list.chatID] == nil {
                order.append(list.chatID)
                grouped[list.chatID] = []
            }
            for sender in list.senders {
                let handle = sender.handle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let key = SenderHandle.normalize(handle) else { continue }
                if seen[list.chatID, default: []].contains(key) { continue }
                seen[list.chatID, default: []].insert(key)
                let name = sender.name.trimmingCharacters(in: .whitespacesAndNewlines)
                grouped[list.chatID, default: []].append(AllowedSender(handle: handle, name: name))
            }
        }
        return order.compactMap { chatID in
            guard let senders = grouped[chatID], !senders.isEmpty else { return nil }
            return ChatSenders(chatID: chatID, senders: senders)
        }
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
        case selfSenderName = "self_sender_name"
        case allowedSenders = "allowed_senders"
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
        selfSenderName = try c.decodeIfPresent(String.self, forKey: .selfSenderName) ?? defaults.selfSenderName
        allowedSenders = try Self.decodeAllowedSenders(c)
        self = sanitized()
    }

    /// キーが無い、null、チャット id の無い要素は、設定全体を落とさずに飛ばす。
    private static func decodeAllowedSenders(_ container: KeyedDecodingContainer<CodingKeys>) throws -> [ChatSenders] {
        guard container.contains(.allowedSenders) else { return [] }
        if try container.decodeNil(forKey: .allowedSenders) { return [] }
        var rows = try container.nestedUnkeyedContainer(forKey: .allowedSenders)
        var lists: [ChatSenders] = []
        while !rows.isAtEnd {
            let row = try rows.nestedContainer(keyedBy: ChatSenders.CodingKeys.self)
            guard let chatID = try row.decodeIfPresent(Int64.self, forKey: .chatID) else { continue }
            let senders = try row.decodeIfPresent([AllowedSender].self, forKey: .senders) ?? []
            lists.append(ChatSenders(chatID: chatID, senders: senders))
        }
        return lists
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
