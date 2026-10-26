import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct FetchedReply: Equatable {
    package var id: String
    package var chatID: Int64?
    package var text: String
    package var inReplyToGUID: String?
    package var createdAt: String?

    package init(
        id: String,
        chatID: Int64? = nil,
        text: String,
        inReplyToGUID: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.chatID = chatID
        self.text = text
        self.inReplyToGUID = inReplyToGUID
        self.createdAt = createdAt
    }
}

package struct ReplyPage: Equatable {
    package var replies: [FetchedReply]
    package var nextCursor: String?
    package var skipped: Int

    package init(replies: [FetchedReply], nextCursor: String?, skipped: Int = 0) {
        self.replies = replies
        self.nextCursor = nextCursor
        self.skipped = skipped
    }
}

package protocol ReplySource: Sendable {
    func fetch(cursor: String?, skipping handledReplyIDs: Set<String>) async throws -> ReplyPage
}

enum ReplyFetchError: Error {
    case secretMode
    case notionToken(SecretReadError)
    case transport
    case badResponse
}

/// 置き場所が決まるまでの取得契約。
/// GET `reply_fetch_url`。未処理の返事は、クライアントが cursor を進めるまで同じ内容を返す。
/// 本文はログに残さない。`reply-secret`（0600）があれば `Authorization: Bearer` を付ける。
/// `in_reply_to_guid` と `created_at` が無い要素はページ全体を失敗させず、件数だけ返す。
package struct HTTPReplySource: ReplySource {
    package var url: URL
    package var secrets: any SecretProviding
    package var session: URLSession

    package init(url: URL, secrets: any SecretProviding, session: URLSession = GenieHTTP.session()) {
        self.url = url
        self.secrets = secrets
        self.session = session
    }

    package func fetch(cursor: String?, skipping handledReplyIDs: Set<String> = []) async throws -> ReplyPage {
        _ = handledReplyIDs
        let secret: String?
        do {
            secret = try secrets.replySecret()
        } catch SecretReadError.insecureMode {
            throw ReplyFetchError.secretMode
        } catch SecretReadError.missing {
            secret = nil
        }
        guard let request = HTTPRequestBuilder.reply(url: url, cursor: cursor, secret: secret) else {
            throw ReplyFetchError.badResponse
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReplyFetchError.transport
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ReplyFetchError.badResponse
        }
        do {
            return try ReplyPageDecoder.decode(data)
        } catch {
            throw ReplyFetchError.badResponse
        }
    }
}

enum ReplyPageDecoder {
    static func decode(_ data: Data) throws -> ReplyPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReplyFetchError.badResponse
        }
        let cursor = object["cursor"] as? String
        let rawReplies = object["replies"] as? [Any] ?? []
        var replies: [FetchedReply] = []
        var skipped = 0
        for item in rawReplies {
            if let reply = one(item) {
                replies.append(reply)
            } else {
                skipped += 1
            }
        }
        return ReplyPage(replies: replies, nextCursor: cursor, skipped: skipped)
    }

    private static func one(_ item: Any) -> FetchedReply? {
        guard let object = item as? [String: Any] else { return nil }
        guard let id = object["id"] as? String else { return nil }
        let text = object["text"] as? String ?? ""
        let guid = object["in_reply_to_guid"] as? String
        let created = object["created_at"] as? String
        let chatID = int64(object["chat_id"])
        return FetchedReply(
            id: id,
            chatID: chatID,
            text: text,
            inReplyToGUID: guid,
            createdAt: created
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let int = value as? Int64 { return int }
        return nil
    }
}

package struct EmptyReplySource: ReplySource {
    package init() {}
    package func fetch(cursor: String?, skipping handledReplyIDs: Set<String> = []) async throws -> ReplyPage {
        _ = handledReplyIDs
        return ReplyPage(replies: [], nextCursor: cursor)
    }
}
