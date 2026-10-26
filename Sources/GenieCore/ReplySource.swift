import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct FetchedReply: Equatable {
    package var id: String
    package var chatID: Int64
    package var text: String
    package var inReplyToGUID: String?

    package init(id: String, chatID: Int64, text: String, inReplyToGUID: String? = nil) {
        self.id = id
        self.chatID = chatID
        self.text = text
        self.inReplyToGUID = inReplyToGUID
    }
}

package struct ReplyPage: Equatable {
    package var replies: [FetchedReply]
    package var nextCursor: String?

    package init(replies: [FetchedReply], nextCursor: String?) {
        self.replies = replies
        self.nextCursor = nextCursor
    }
}

package protocol ReplySource: Sendable {
    func fetch(cursor: String?) async throws -> ReplyPage
}

enum ReplyFetchError: Error {
    case secretMode
    case transport
    case badResponse
}

/// 置き場所が決まるまでの取得契約。
/// GET `reply_fetch_url`。未処理の返事は、クライアントが cursor を進めるまで同じ内容を返す。
/// 本文はログに残さない。`reply-secret`（0600）があれば `Authorization: Bearer` を付ける。
package struct HTTPReplySource: ReplySource {
    package var url: URL
    package var secrets: any SecretProviding
    package var session: URLSession

    package init(url: URL, secrets: any SecretProviding, session: URLSession = .shared) {
        self.url = url
        self.secrets = secrets
        self.session = session
    }

    package func fetch(cursor: String?) async throws -> ReplyPage {
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
        let raw = try JSONDecoder().decode(RawPage.self, from: data)
        let replies = raw.replies.map { item in
            FetchedReply(
                id: item.id,
                chatID: item.chatID,
                text: item.text,
                inReplyToGUID: item.inReplyToGUID
            )
        }
        return ReplyPage(replies: replies, nextCursor: raw.cursor)
    }
}

private struct RawPage: Decodable {
    var cursor: String?
    var replies: [RawReply]
}

private struct RawReply: Decodable {
    var id: String
    var chatID: Int64
    var text: String
    var inReplyToGUID: String?

    enum CodingKeys: String, CodingKey {
        case id, text
        case chatID = "chat_id"
        case inReplyToGUID = "in_reply_to_guid"
    }
}

package struct EmptyReplySource: ReplySource {
    package init() {}
    package func fetch(cursor: String?) async throws -> ReplyPage {
        ReplyPage(replies: [], nextCursor: cursor)
    }
}
