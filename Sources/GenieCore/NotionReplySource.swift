import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// データソース query に付ける Notion-Version。公式の filter 例（2026-03-11）に合わせた定数。
enum NotionAPI {
    static let version = "2026-03-11"
    static let minimumInterval = 1.0 / 3.0
    static let pageSize = 100
    static let maxPages = 20
    static let maxRetries = 5
    /// 水位よりこの秒数だけ前から読み直す。分に丸めた created_time と、行が見えるまでの遅れを吸収する。
    static let lookbackSeconds: TimeInterval = 120
    static let seenCap = 5000
    static let retryCapSeconds = 60.0
}

enum NotionDataSourceID {
    /// パスに埋め込める UUID だけを受け付ける。
    static func canonical(_ raw: String) -> String? {
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let start = hex.startIndex
        let cuts = [8, 12, 16, 20, 32]
        var parts: [String] = []
        var previous = 0
        for cut in cuts {
            let lower = hex.index(start, offsetBy: previous)
            let upper = hex.index(start, offsetBy: cut)
            parts.append(String(hex[lower..<upper]))
            previous = cut
        }
        return parts.joined(separator: "-")
    }
}

struct NotionSeenID: Codable, Equatable {
    var id: String
    var at: String
}

struct NotionCursor: Codable, Equatable {
    /// 読み終えた行のうち最も新しい created_at。未処理の返事があるときは、その時刻より新しくはしない。
    var createdAt: String
    /// 読み直し幅の中で既に見た reply_id。
    var seen: [NotionSeenID]
    /// カーソルを作り始めた分の先頭。これより前は読まない。
    var notBefore: String?

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case seen
        case notBefore = "not_before"
        case replyIDs = "reply_ids"
        case pendingAt = "pending_at"
        case pendingIDs = "pending_ids"
    }

    init(createdAt: String, seen: [NotionSeenID], notBefore: String? = nil) {
        self.createdAt = createdAt
        self.seen = seen
        self.notBefore = notBefore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let created = try container.decode(String.self, forKey: .createdAt)
        if let seen = try container.decodeIfPresent([NotionSeenID].self, forKey: .seen) {
            createdAt = created
            self.seen = seen
            notBefore = try container.decodeIfPresent(String.self, forKey: .notBefore)
            return
        }
        notBefore = nil
        var items: [NotionSeenID] = []
        let ids = try container.decodeIfPresent([String].self, forKey: .replyIDs) ?? []
        for id in ids where !id.isEmpty {
            items.append(NotionSeenID(id: id, at: created))
        }
        if let pending = try container.decodeIfPresent(String.self, forKey: .pendingAt) {
            let pendingIDs = try container.decodeIfPresent([String].self, forKey: .pendingIDs) ?? []
            for id in pendingIDs where !id.isEmpty {
                items.append(NotionSeenID(id: id, at: pending))
            }
            createdAt = pending > created ? pending : created
        } else {
            createdAt = created
        }
        seen = items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(seen, forKey: .seen)
        try container.encodeIfPresent(notBefore, forKey: .notBefore)
    }

    func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String?) -> NotionCursor? {
        guard let raw, let data = raw.data(using: .utf8), !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(NotionCursor.self, from: data)
    }

    /// カーソルが空のときは、今の分の先頭から読む。それより古い行は読まない。
    static func freshStart(now: Date) -> String {
        let floored = floor(now.timeIntervalSince1970 / 60) * 60
        return ISO8601.string(from: Date(timeIntervalSince1970: floored))
    }

    func queryStart(now: Date) -> String {
        let lookback: String
        if let frontier = ISO8601.date(from: createdAt) {
            lookback = ISO8601.string(from: frontier.addingTimeInterval(-NotionAPI.lookbackSeconds))
        } else {
            lookback = Self.freshStart(now: now)
        }
        if let notBefore, notBefore > lookback {
            return notBefore
        }
        return lookback
    }

    mutating func prune() {
        guard let frontier = ISO8601.date(from: createdAt) else { return }
        let start = ISO8601.string(from: frontier.addingTimeInterval(-NotionAPI.lookbackSeconds))
        seen.removeAll { $0.at < start }
        seen.sort { lhs, rhs in
            if lhs.at == rhs.at { return lhs.id < rhs.id }
            return lhs.at < rhs.at
        }
        if seen.count > NotionAPI.seenCap {
            seen = Array(seen.suffix(NotionAPI.seenCap))
        }
    }

    static func ids(in raw: String?) -> Set<String> {
        Set(decode(raw)?.seen.map(\.id) ?? [])
    }

    /// 未処理の返事より先に水位を進めない。その ID は見たと覚えないので、次も読み直す。
    static func reconcile(proposed: String?, unhandled: [FetchedReply]) -> String? {
        guard let proposed, var cursor = decode(proposed) else { return proposed }
        guard !unhandled.isEmpty else { return proposed }
        let drop = Set(unhandled.map(\.id))
        cursor.seen.removeAll { drop.contains($0.id) }
        if let oldest = unhandled.compactMap(\.createdAt).filter({ !$0.isEmpty }).min(),
           cursor.createdAt > oldest {
            cursor.createdAt = oldest
        }
        cursor.prune()
        return cursor.encoded()
    }
}

struct NotionCandidate {
    var replyID: String
    var createdAt: String
    var reply: FetchedReply?
}

struct NotionAdvance {
    var replies: [FetchedReply]
    var skipped: Int
    var cursor: NotionCursor
    var reachedLimit: Bool
}

/// 水位の 120 秒前から読み、処理済みと見たと覚えた ID は件数に数えない。
enum NotionRead {
    static func collect(
        cursor: NotionCursor?,
        rows: [NotionCandidate],
        handled: Set<String>,
        limit: Int,
        now: Date
    ) -> NotionAdvance {
        let cap = max(1, limit)
        let lowerBound = cursor?.queryStart(now: now) ?? NotionCursor.freshStart(now: now)
        let notBefore = cursor?.notBefore ?? NotionCursor.freshStart(now: now)
        var known: [String: String] = [:]
        for item in cursor?.seen ?? [] where !item.id.isEmpty {
            known[item.id] = item.at
        }
        var replies: [FetchedReply] = []
        var skipped = 0
        var reachedLimit = false
        var newest = cursor?.createdAt ?? ""
        let ordered = rows.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.replyID < rhs.replyID }
            return lhs.createdAt < rhs.createdAt
        }
        for row in ordered {
            if row.replyID.isEmpty || row.createdAt.isEmpty {
                skipped += 1
                continue
            }
            if row.createdAt < lowerBound { continue }
            if known[row.replyID] != nil || handled.contains(row.replyID) {
                known[row.replyID] = row.createdAt
                if newest.isEmpty || row.createdAt > newest {
                    newest = row.createdAt
                }
                continue
            }
            if replies.count >= cap {
                reachedLimit = true
                break
            }
            if let reply = row.reply {
                replies.append(reply)
            } else {
                skipped += 1
            }
            known[row.replyID] = row.createdAt
            if newest.isEmpty || row.createdAt > newest {
                newest = row.createdAt
            }
        }
        if newest.isEmpty {
            newest = NotionCursor.freshStart(now: now)
        }
        var next = NotionCursor(
            createdAt: newest,
            seen: known.map { NotionSeenID(id: $0.key, at: $0.value) },
            notBefore: notBefore
        )
        next.prune()
        return NotionAdvance(replies: replies, skipped: skipped, cursor: next, reachedLimit: reachedLimit)
    }
}

struct NotionHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

protocol NotionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> NotionHTTPResponse
}

struct URLSessionNotionTransport: NotionTransport {
    var session: URLSession

    func send(_ request: URLRequest) async throws -> NotionHTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReplyFetchError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReplyFetchError.transport
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return NotionHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

struct NotionQueryPage {
    var rows: [NotionCandidate]
    var hasMore: Bool
    var nextCursor: String?
    var skipped: Int
}

/// Notion のデータソースを created_time の古い順に読む。本文はログに出さない。
final class NotionPace: @unchecked Sendable {
    private var last: Date?

    func wait(_ clock: any GenieClock) async throws {
        if let last {
            let elapsed = clock.now().timeIntervalSince(last)
            if elapsed < NotionAPI.minimumInterval {
                self.last = last.addingTimeInterval(NotionAPI.minimumInterval)
                try await clock.sleep(seconds: NotionAPI.minimumInterval - elapsed)
                return
            }
        }
        last = clock.now()
    }
}

package struct NotionReplySource: ReplySource {
    package var dataSourceID: String
    package var secrets: any SecretProviding
    package var clock: any GenieClock
    package var pageLimit: Int
    var transport: any NotionTransport
    private var pace = NotionPace()

    package init(
        dataSourceID: String,
        secrets: any SecretProviding,
        clock: any GenieClock = SystemClock(),
        pageLimit: Int = NotionAPI.pageSize,
        session: URLSession = GenieHTTP.session()
    ) {
        self.dataSourceID = dataSourceID
        self.secrets = secrets
        self.clock = clock
        self.pageLimit = pageLimit
        self.transport = URLSessionNotionTransport(session: session)
    }

    init(
        dataSourceID: String,
        secrets: any SecretProviding,
        clock: any GenieClock,
        pageLimit: Int,
        transport: any NotionTransport
    ) {
        self.dataSourceID = dataSourceID
        self.secrets = secrets
        self.clock = clock
        self.pageLimit = pageLimit
        self.transport = transport
    }

    package func fetch(cursor: String?, skipping handledReplyIDs: Set<String> = []) async throws -> ReplyPage {
        guard let id = NotionDataSourceID.canonical(dataSourceID),
              let url = URL(string: "https://api.notion.com/v1/data_sources/\(id)/query") else {
            throw ReplyFetchError.badResponse
        }
        let token: String
        do {
            token = try secrets.notionToken()
        } catch let error as SecretReadError {
            throw ReplyFetchError.notionToken(error)
        }
        let stored = NotionCursor.decode(cursor)
        let lowerBound = stored?.queryStart(now: clock.now()) ?? NotionCursor.freshStart(now: clock.now())
        var start: String?
        var collected: [NotionCandidate] = []
        var skippedInPages = 0
        for _ in 0..<NotionAPI.maxPages {
            let page = try await query(url: url, token: token, lowerBound: lowerBound, startCursor: start)
            collected.append(contentsOf: page.rows)
            skippedInPages += page.skipped
            let partial = NotionRead.collect(
                cursor: stored,
                rows: collected,
                handled: handledReplyIDs,
                limit: pageLimit,
                now: clock.now()
            )
            if partial.reachedLimit || !page.hasMore {
                return ReplyPage(
                    replies: partial.replies,
                    nextCursor: partial.cursor.encoded(),
                    skipped: skippedInPages + partial.skipped
                )
            }
            guard let next = page.nextCursor, !next.isEmpty else {
                return ReplyPage(
                    replies: partial.replies,
                    nextCursor: partial.cursor.encoded(),
                    skipped: skippedInPages + partial.skipped
                )
            }
            start = next
        }
        let advanced = NotionRead.collect(
            cursor: stored,
            rows: collected,
            handled: handledReplyIDs,
            limit: pageLimit,
            now: clock.now()
        )
        return ReplyPage(
            replies: advanced.replies,
            nextCursor: advanced.cursor.encoded(),
            skipped: skippedInPages + advanced.skipped
        )
    }

    private func query(
        url: URL,
        token: String,
        lowerBound: String,
        startCursor: String?
    ) async throws -> NotionQueryPage {
        var attempt = 0
        while true {
            attempt += 1
            try await pace.wait(clock)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(NotionAPI.version, forHTTPHeaderField: "Notion-Version")
            request.httpBody = try Self.body(lowerBound: lowerBound, startCursor: startCursor)
            let response: NotionHTTPResponse
            do {
                response = try await transport.send(request)
            } catch let error as ReplyFetchError {
                throw error
            } catch {
                throw ReplyFetchError.transport
            }
            if Self.retries(status: response.status) {
                let delay = Self.retryDelay(headers: response.headers, attempt: attempt)
                try await clock.sleep(seconds: delay)
                if attempt >= NotionAPI.maxRetries {
                    throw ReplyFetchError.transport
                }
                continue
            }
            guard (200...299).contains(response.status) else {
                throw ReplyFetchError.badResponse
            }
            return try NotionPageDecoder.decode(response.body)
        }
    }

    private static func retries(status: Int) -> Bool {
        status == 429 || status == 529 || status == 500 || status == 503
    }

    private static func retryDelay(headers: [String: String], attempt: Int) -> Double {
        if let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Double(raw), seconds >= 0 {
            return min(NotionAPI.retryCapSeconds, max(seconds, NotionAPI.minimumInterval))
        }
        return min(NotionAPI.retryCapSeconds, pow(2, Double(max(0, attempt - 1))))
    }

    private static func body(lowerBound: String, startCursor: String?) throws -> Data {
        var object: [String: Any] = [
            "page_size": NotionAPI.pageSize,
            "sorts": [["timestamp": "created_time", "direction": "ascending"]],
            "filter": [
                "timestamp": "created_time",
                "created_time": ["on_or_after": lowerBound],
            ],
        ]
        if let startCursor, !startCursor.isEmpty {
            object["start_cursor"] = startCursor
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

enum NotionNumber: Equatable {
    case absent
    case exact(Int64)
    case invalid
}

enum NotionPageDecoder {
    static func decode(_ data: Data) throws -> NotionQueryPage {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let tokens = chatIDTokens(in: raw)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReplyFetchError.badResponse
        }
        let results = object["results"] as? [Any] ?? []
        var rows: [NotionCandidate] = []
        var skipped = 0
        var tokenIndex = 0
        for item in results {
            let chat: NotionNumber
            if hasChatID(item) {
                if tokenIndex < tokens.count {
                    chat = tokens[tokenIndex]
                    tokenIndex += 1
                } else {
                    chat = number(chatProperty(item))
                }
            } else {
                chat = .absent
            }
            if let row = candidate(item, chat: chat) {
                rows.append(row)
            } else {
                skipped += 1
            }
        }
        let hasMore = object["has_more"] as? Bool ?? false
        let next = object["next_cursor"] as? String
        return NotionQueryPage(rows: rows, hasMore: hasMore, nextCursor: next, skipped: skipped)
    }

    /// JSON の数値は 2^53 を超えると丸まる。chat_id は原文の桁のまま読む。
    static func chatIDTokens(in raw: String) -> [NotionNumber] {
        var tokens: [NotionNumber] = []
        var rest = Substring(raw)
        while let key = rest.range(of: "\"chat_id\"") {
            var search = rest[key.upperBound...]
            var matched = false
            while let numberKey = search.range(of: "\"number\"") {
                let afterQuotes = search[numberKey.upperBound...]
                let afterSpace = afterQuotes.drop(while: { $0.isWhitespace })
                // `"type":"number"` の値ではなく、`"number":` のキーだけを読む。
                guard afterSpace.first == ":" else {
                    search = afterQuotes
                    continue
                }
                let value = afterSpace.dropFirst().drop(while: { $0.isWhitespace })
                if value.hasPrefix("null") {
                    tokens.append(.absent)
                } else {
                    let token = value.prefix { character in
                        character == "-" || character == "+" || character == "." || character == "e" || character == "E" || character.isNumber
                    }
                    let text = String(token)
                    if let parsed = Int64(text),
                       !text.contains("."), !text.contains("e"), !text.contains("E"), !text.contains("+") {
                        tokens.append(.exact(parsed))
                    } else {
                        tokens.append(.invalid)
                    }
                }
                rest = value
                matched = true
                break
            }
            if !matched { break }
        }
        return tokens
    }

    private static func candidate(_ item: Any, chat: NotionNumber) -> NotionCandidate? {
        guard let page = item as? [String: Any] else { return nil }
        if page["object"] as? String == "page", page["in_trash"] as? Bool == true {
            return nil
        }
        let properties = page["properties"] as? [String: Any] ?? [:]
        let replyID = plain(properties["reply_id"], key: "title").trimmingCharacters(in: .whitespacesAndNewlines)
        let created = normalizeTime(createdTime(properties["created_at"], fallback: page["created_time"] as? String))
        let guid = plain(properties["in_reply_to_guid"], key: "rich_text")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = plain(properties["text"], key: "rich_text")
        if chat == .invalid {
            return NotionCandidate(replyID: replyID, createdAt: created, reply: nil)
        }
        let chatID: Int64?
        if case .exact(let value) = chat {
            chatID = value
        } else {
            chatID = nil
        }
        let deliverable = !replyID.isEmpty && !created.isEmpty && !guid.isEmpty && !text.isEmpty
        let reply = deliverable
            ? FetchedReply(id: replyID, chatID: chatID, text: text, inReplyToGUID: guid, createdAt: created)
            : nil
        return NotionCandidate(replyID: replyID, createdAt: created, reply: reply)
    }

    private static func hasChatID(_ item: Any) -> Bool {
        chatProperty(item) != nil
    }

    private static func chatProperty(_ item: Any) -> Any? {
        guard let page = item as? [String: Any],
              let properties = page["properties"] as? [String: Any] else { return nil }
        return properties["chat_id"]
    }

    private static func createdTime(_ property: Any?, fallback: String?) -> String {
        if let object = property as? [String: Any], let text = object["created_time"] as? String, !text.isEmpty {
            return text
        }
        return fallback ?? ""
    }

    private static func plain(_ property: Any?, key: String) -> String {
        guard let object = property as? [String: Any] else { return "" }
        let parts = object[key] as? [Any] ?? []
        return parts.compactMap { item -> String? in
            (item as? [String: Any])?["plain_text"] as? String
        }.joined()
    }

    private static func number(_ property: Any?) -> NotionNumber {
        guard let object = property as? [String: Any] else { return .absent }
        let value = object["number"]
        if value == nil || value is NSNull { return .absent }
        if let text = value as? String {
            if let parsed = Int64(text), !text.contains("."), !text.contains("e"), !text.contains("E") {
                return .exact(parsed)
            }
            return .invalid
        }
        if let number = value as? NSNumber {
            let text = number.stringValue
            if let parsed = Int64(text), !text.contains("."), !text.contains("e"), !text.contains("E") {
                return .exact(parsed)
            }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), abs(double) <= 9_007_199_254_740_992 else {
                return .invalid
            }
            return .exact(number.int64Value)
        }
        if let int = value as? Int { return .exact(Int64(int)) }
        if let int = value as? Int64 { return .exact(int) }
        return .invalid
    }

    private static func normalizeTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = ISO8601.date(from: trimmed) else { return trimmed }
        return ISO8601.string(from: date)
    }
}
