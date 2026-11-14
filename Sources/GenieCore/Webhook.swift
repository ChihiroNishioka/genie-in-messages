import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum WebhookRetry {
    static func shouldRetry(statusCode: Int) -> Bool {
        if statusCode == 408 || statusCode == 429 { return true }
        return (500...599).contains(statusCode)
    }

    static func delay(attempt: Int, initial: Double, cap: Double) -> Double {
        let power = max(0, attempt - 1)
        let multiplier = pow(2.0, Double(power))
        return min(cap, max(0, initial) * multiplier)
    }
}

package struct WebhookHTTPResult: Equatable {
    package var statusCode: Int
    package init(statusCode: Int) { self.statusCode = statusCode }
}

package protocol WebhookPosting: Sendable {
    func post(url: URL, secret: String, body: Data, idempotencyKey: String) async throws -> WebhookHTTPResult
}

enum WebhookCallError: Error {
    case transport
}

struct WebhookPayload: Encodable {
    var v: Int
    var event: String
    var idempotencyKey: String
    var guid: String
    var chatID: Int64
    var text: String
    var createdAt: String?
    var senderIsMe: Bool
    var senderName: String
    var senderHandle: String? = nil

    enum CodingKeys: String, CodingKey {
        case v, event, guid, text
        case idempotencyKey = "idempotency_key"
        case chatID = "chat_id"
        case createdAt = "created_at"
        case senderIsMe = "sender_is_me"
        case senderName = "sender_name"
        case senderHandle = "sender_handle"
    }

    func encodeData() throws -> Data {
        try StateCoding.encoder().encode(self)
    }
}

enum EndpointURL {
    static func httpsOrLoopback(_ text: String) -> URL? {
        if let url = https(text) { return url }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host) else { return nil }
        return url
    }
    static func https(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum GenieHTTP {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

enum HTTPRequestBuilder {
    static func webhook(url: URL, secret: String, body: Data, idempotencyKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = body
        return request
    }

    static func reply(url: URL, cursor: String?, secret: String?) -> URLRequest? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let composed = components.url else { return nil }
        var request = URLRequest(url: composed)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let secret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

package struct URLSessionWebhook: WebhookPosting {
    package var session: URLSession

    package init(session: URLSession = GenieHTTP.session()) {
        self.session = session
    }

    package func post(url: URL, secret: String, body: Data, idempotencyKey: String) async throws -> WebhookHTTPResult {
        let request = HTTPRequestBuilder.webhook(
            url: url,
            secret: secret,
            body: body,
            idempotencyKey: idempotencyKey
        )
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebhookCallError.transport
            }
            return WebhookHTTPResult(statusCode: http.statusCode)
        } catch let error as WebhookCallError {
            throw error
        } catch {
            throw WebhookCallError.transport
        }
    }
}
