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

struct NotionCursor: Codable, Equatable {
    var createdAt: String
    var replyIDs: [String]
    /// より新しい時刻を見たが、同じ時刻の行を次の取得でも拾うため、まだ水位にしていない。
    var pendingAt: String?
    var pendingIDs: [String]

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case replyIDs = "reply_ids"
        case pendingAt = "pending_at"
        case pendingIDs = "pending_ids"
    }

    init(createdAt: String, replyIDs: [String], pendingAt: String? = nil, pendingIDs: [String] = []) {
        self.createdAt = createdAt
        self.replyIDs = replyIDs
        self.pendingAt = pendingAt
        self.pendingIDs = pendingIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        replyIDs = try container.decodeIfPresent([String].self, forKey: .replyIDs) ?? []
        pendingAt = try container.decodeIfPresent(String.self, forKey: .pendingAt)
        pendingIDs = try container.decodeIfPresent([String].self, forKey: .pendingIDs) ?? []
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
}

struct NotionCandidate {
    var replyID: String
    var createdAt: String
    var reply: FetchedReply?
}

struct NotionAdvance {
    var replies: [FetchedReply]
    var skipped: Int
    var cursor: NotionCursor?
    var truncated: Bool
}

/// created_time は分単位で同じ値になる。水位はその時刻と、そこで見た reply_id の組。
/// より新しい時刻を初めて見たら、次の取得まで水位を動かさず、同じ時刻の後着を拾う。
enum NotionRead {
    static func advance(
        cursor: NotionCursor?,
        rows: [NotionCandidate],
        scanComplete: Bool,
        limit: Int
    ) -> NotionAdvance {
        let cap = max(1, limit)
        var open = cursor?.createdAt
        var openIDs = Set(cursor?.replyIDs ?? [])
        let hadPending = cursor?.pendingAt != nil
        var pending = cursor?.pendingAt
        var pendingIDs = Set(cursor?.pendingIDs ?? [])
        var foundNewAtOpen = false
        var replies: [FetchedReply] = []
        var skipped = 0
        var truncated = false

        func take(_ row: NotionCandidate) -> Bool {
            guard let reply = row.reply else {
                skipped += 1
                return true
            }
            if replies.count >= cap {
                truncated = true
                return false
            }
            replies.append(reply)
            return true
        }

        for row in rows {
            if row.replyID.isEmpty || row.createdAt.isEmpty {
                skipped += 1
                continue
            }
            if let open, row.createdAt < open {
                continue
            }
            if let open, row.createdAt == open {
                if openIDs.contains(row.replyID) { continue }
                if !take(row) { break }
                openIDs.insert(row.replyID)
                foundNewAtOpen = true
                continue
            }
            if open == nil {
                if !take(row) { break }
                open = row.createdAt
                openIDs = [row.replyID]
                foundNewAtOpen = true
                continue
            }
            if let pending, row.createdAt < pending {
                _ = take(row)
                if truncated { break }
                continue
            }
            if let pending, row.createdAt == pending {
                if pendingIDs.contains(row.replyID) { continue }
                if !take(row) { break }
                pendingIDs.insert(row.replyID)
                continue
            }
            if !take(row) { break }
            pending = row.createdAt
            pendingIDs = [row.replyID]
        }

        let complete = scanComplete && !truncated
        if hadPending, !foundNewAtOpen, complete, let newest = pending {
            open = newest
            openIDs = pendingIDs
            pending = nil
            pendingIDs = []
        }
        if openIDs.count > 5000 {
            openIDs = Set(Array(openIDs).sorted().suffix(5000))
        }
        if pendingIDs.count > 5000 {
            pendingIDs = Set(Array(pendingIDs).sorted().suffix(5000))
        }

        let next: NotionCursor?
        if let open {
            next = NotionCursor(
                createdAt: open,
                replyIDs: openIDs.sorted(),
                pendingAt: pending,
                pendingIDs: pendingIDs.sorted()
            )
        } else {
            next = nil
        }
        return NotionAdvance(replies: replies, skipped: skipped, cursor: next, truncated: truncated)
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

    package func fetch(cursor: String?) async throws -> ReplyPage {
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
        var start: String?
        var collected: [NotionCandidate] = []
        var skippedInPages = 0
        var scanComplete = false
        for _ in 0..<NotionAPI.maxPages {
            let page = try await query(url: url, token: token, cursor: stored, startCursor: start)
            collected.append(contentsOf: page.rows)
            skippedInPages += page.skipped
            let partial = NotionRead.advance(
                cursor: stored,
                rows: collected,
                scanComplete: false,
                limit: pageLimit
            )
            if !page.hasMore {
                scanComplete = true
                break
            }
            if partial.truncated || partial.replies.count >= max(1, pageLimit) {
                break
            }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            start = next
        }
        let advanced = NotionRead.advance(
            cursor: stored,
            rows: collected,
            scanComplete: scanComplete,
            limit: pageLimit
        )
        return ReplyPage(
            replies: advanced.replies,
            nextCursor: advanced.cursor?.encoded(),
            skipped: skippedInPages + advanced.skipped
        )
    }

    private func query(
        url: URL,
        token: String,
        cursor: NotionCursor?,
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
            request.httpBody = try Self.body(cursor: cursor, startCursor: startCursor)
            let response: NotionHTTPResponse
            do {
                response = try await transport.send(request)
            } catch let error as ReplyFetchError {
                throw error
            } catch {
                throw ReplyFetchError.transport
            }
            if response.status == 429 {
                if attempt >= NotionAPI.maxRetries {
                    throw ReplyFetchError.transport
                }
                let delay = Self.retryDelay(headers: response.headers, attempt: attempt)
                try await clock.sleep(seconds: delay)
                continue
            }
            guard (200...299).contains(response.status) else {
                throw ReplyFetchError.badResponse
            }
            return try NotionPageDecoder.decode(response.body)
        }
    }

    private static func retryDelay(headers: [String: String], attempt: Int) -> Double {
        if let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Double(raw), seconds >= 0 {
            return max(seconds, NotionAPI.minimumInterval)
        }
        return min(60, pow(2, Double(max(0, attempt - 1))))
    }

    private static func body(cursor: NotionCursor?, startCursor: String?) throws -> Data {
        var object: [String: Any] = [
            "page_size": NotionAPI.pageSize,
            "sorts": [["timestamp": "created_time", "direction": "ascending"]],
        ]
        if let createdAt = cursor?.createdAt, !createdAt.isEmpty {
            object["filter"] = [
                "timestamp": "created_time",
                "created_time": ["on_or_after": createdAt],
            ]
        }
        if let startCursor, !startCursor.isEmpty {
            object["start_cursor"] = startCursor
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

enum NotionPageDecoder {
    static func decode(_ data: Data) throws -> NotionQueryPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReplyFetchError.badResponse
        }
        let results = object["results"] as? [Any] ?? []
        var rows: [NotionCandidate] = []
        var skipped = 0
        for item in results {
            if let row = candidate(item) {
                rows.append(row)
            } else {
                skipped += 1
            }
        }
        let hasMore = object["has_more"] as? Bool ?? false
        let next = object["next_cursor"] as? String
        return NotionQueryPage(rows: rows, hasMore: hasMore, nextCursor: next, skipped: skipped)
    }

    private static func candidate(_ item: Any) -> NotionCandidate? {
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
        let chatID = number(properties["chat_id"])
        let deliverable = !replyID.isEmpty && !created.isEmpty && !guid.isEmpty && !text.isEmpty
        let reply = deliverable
            ? FetchedReply(id: replyID, chatID: chatID, text: text, inReplyToGUID: guid, createdAt: created)
            : nil
        return NotionCandidate(replyID: replyID, createdAt: created, reply: reply)
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

    private static func number(_ property: Any?) -> Int64? {
        guard let object = property as? [String: Any] else { return nil }
        let value = object["number"]
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let int = value as? Int64 { return int }
        return nil
    }

    private static func normalizeTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = ISO8601.date(from: trimmed) else { return trimmed }
        return ISO8601.string(from: date)
    }
}
