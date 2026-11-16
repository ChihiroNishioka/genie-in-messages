import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OutboundQueryPage {
    var entries: [FetchedOutbound]
    var hasMore: Bool
    var nextCursor: String?
}

enum OutboundPageDecoder {
    static func decode(_ data: Data, now: Date) throws -> OutboundQueryPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [Any],
              let hasMore = object["has_more"] as? Bool else { throw ReplyFetchError.badResponse }
        let entries = try results.map { item -> FetchedOutbound in
            guard let page = item as? [String: Any],
                  let pageID = page["id"] as? String, !pageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let created = page["created_time"] as? String,
                  let date = ISO8601.date(from: created) else { throw ReplyFetchError.badResponse }
            let properties = page["properties"] as? [String: Any] ?? [:]
            let key = plain(properties["idempotency_key"], type: "title")
            let targetRaw = plain(properties["target"], type: "rich_text")
            let text = plain(properties["text"], type: "rich_text")
            let target = targetRaw.flatMap(OutboundTarget.init(rawValue:))
            var invalid: String?
            if key == nil || key?.isEmpty == true || (key?.utf8.count ?? 0) > 128
                || key?.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 58].contains($0) }) != true
                || targetRaw == nil || text == nil || date.timeIntervalSince(now) > 60 {
                invalid = "outbound_bad_entry"
            } else if target == nil {
                invalid = "outbound_unknown_target"
            }
            if let createdProperty = properties["created_at"] as? [String: Any],
               createdProperty["type"] as? String == "created_time",
               let value = createdProperty["created_time"] as? String,
               let propertyDate = ISO8601.date(from: value), propertyDate == date {
            } else {
                invalid = "outbound_bad_entry"
            }
            if page["in_trash"] as? Bool == true || page["archived"] as? Bool == true {
                invalid = "outbound_bad_entry"
            }
            return FetchedOutbound(pageID: pageID, idempotencyKey: key, target: target, text: text,
                createdAt: ISO8601.string(from: date), invalidCode: invalid)
        }
        let next = object["next_cursor"] as? String
        if hasMore && (next?.isEmpty != false) { throw ReplyFetchError.badResponse }
        return OutboundQueryPage(entries: entries, hasMore: hasMore, nextCursor: next)
    }

    private static func plain(_ raw: Any?, type: String) -> String? {
        guard let property = raw as? [String: Any], property["type"] as? String == type,
              let parts = property[type] as? [Any] else { return nil }
        var value = ""
        for item in parts {
            guard let object = item as? [String: Any], object["type"] as? String != nil,
                  let text = object["plain_text"] as? String else { return nil }
            value += text
        }
        return value
    }
}

package struct NotionOutboundSource: OutboundSource {
    package var dataSourceID: String
    package var secrets: any SecretProviding
    package var clock: any GenieClock
    package var pageLimit: Int
    var transport: any NotionTransport
    var pace: NotionPace

    package init(dataSourceID: String, secrets: any SecretProviding, clock: any GenieClock = SystemClock(), pageLimit: Int = NotionAPI.pageSize, session: URLSession = GenieHTTP.session()) {
        self.dataSourceID = dataSourceID
        self.secrets = secrets
        self.clock = clock
        self.pageLimit = pageLimit
        self.transport = URLSessionNotionTransport(session: session)
        self.pace = .shared
    }

    init(dataSourceID: String, secrets: any SecretProviding, clock: any GenieClock, pageLimit: Int, transport: any NotionTransport, pace: NotionPace = NotionPace()) {
        self.dataSourceID = dataSourceID
        self.secrets = secrets
        self.clock = clock
        self.pageLimit = pageLimit
        self.transport = transport
        self.pace = pace
    }

    package func fetch(cursor: String?, skipping pageIDs: Set<String> = [], holding heldPageIDs: Set<String> = []) async throws -> OutboundPage {
        guard let id = NotionDataSourceID.canonical(dataSourceID),
              let url = URL(string: "https://api.notion.com/v1/data_sources/\(id)/query") else { throw ReplyFetchError.badResponse }
        let token: String
        do { token = try secrets.notionToken() }
        catch let error as SecretReadError { throw ReplyFetchError.notionToken(error) }
        let now = clock.now()
        let stored = NotionCursor.decode(cursor)
        let lower = stored?.queryStart(now: now) ?? NotionCursor.freshStart(now: now)
        let client = NotionQueryClient(transport: transport, clock: clock, pace: pace)
        var entries: [FetchedOutbound] = []
        var start: String?
        for _ in 0..<NotionAPI.maxPages {
            let data = try await client.query(url: url, token: token, lowerBound: lower, startCursor: start)
            let page = try OutboundPageDecoder.decode(data, now: now)
            entries.append(contentsOf: page.entries)
            let advance = collect(entries, stored: stored, skipping: pageIDs, holding: heldPageIDs, now: now)
            if advance.limited || !page.hasMore { return advance.page }
            start = page.nextCursor
        }
        return collect(entries, stored: stored, skipping: pageIDs, holding: heldPageIDs, now: now).page
    }

    private func collect(_ rows: [FetchedOutbound], stored: NotionCursor?, skipping: Set<String>, holding: Set<String>, now: Date) -> (page: OutboundPage, limited: Bool) {
        let lower = stored?.queryStart(now: now) ?? NotionCursor.freshStart(now: now)
        var seen = Dictionary((stored?.seen ?? []).map { ($0.id, $0.at) }, uniquingKeysWith: max)
        var newest = stored?.createdAt ?? NotionCursor.freshStart(now: now)
        var entries: [FetchedOutbound] = []
        var fresh = 0
        var limited = false
        let ordered = rows.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.pageID < rhs.pageID : lhs.createdAt < rhs.createdAt
        }
        for row in ordered where row.createdAt >= lower {
            let pageID = OutboundHash.digest(kind: "page", values: [row.pageID])
            if (seen[pageID] != nil && !holding.contains(pageID)) || skipping.contains(pageID) {
                seen[pageID] = row.createdAt
                newest = max(newest, row.createdAt)
                continue
            }
            let parked = holding.contains(pageID)
            if !parked && row.invalidCode == nil && fresh >= max(1, pageLimit) {
                limited = true
                break
            }
            entries.append(row)
            seen[pageID] = row.createdAt
            newest = max(newest, row.createdAt)
            if !parked && row.invalidCode == nil { fresh += 1 }
        }
        var cursor = NotionCursor(createdAt: newest, seen: seen.map { NotionSeenID(id: $0.key, at: $0.value) }, notBefore: stored?.notBefore ?? NotionCursor.freshStart(now: now))
        cursor.prune()
        return (OutboundPage(entries: entries, nextCursor: cursor.encoded()), limited)
    }
}

package struct ConfiguredOutboundSource: OutboundSource {
    package var config: FileConfigProvider
    package var secrets: FileSecretProvider
    private let pace: NotionPace

    package init(config: FileConfigProvider, secrets: FileSecretProvider) {
        self.config = config
        self.secrets = secrets
        self.pace = .shared
    }

    package func prepared(for config: GenieConfig) -> any OutboundSource {
        guard config.outboundEnabled else { return EmptyOutboundSource() }
        var source = NotionOutboundSource(dataSourceID: config.outboundNotionDataSourceID, secrets: secrets, pageLimit: config.replyPageLimit)
        source.pace = pace
        return source
    }

    package func fetch(cursor: String?, skipping pageIDs: Set<String>, holding heldPageIDs: Set<String>) async throws -> OutboundPage {
        try await prepared(for: config.load()).fetch(cursor: cursor, skipping: pageIDs, holding: heldPageIDs)
    }
}
