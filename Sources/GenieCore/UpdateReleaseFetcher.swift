import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct ReleaseHTTPResponse: Sendable {
    package let statusCode: Int
    package let headers: [String: String]
    package let body: Data

    package init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

package protocol ReleaseTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ReleaseHTTPResponse
}

package struct URLSessionReleaseTransport: ReleaseTransport {
    package var session: URLSession

    package init(session: URLSession = GenieHTTP.session()) {
        self.session = session
    }

    package func send(_ request: URLRequest) async throws -> ReleaseHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateTransportError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return ReleaseHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

private enum UpdateTransportError: Error {
    case invalidResponse
}

extension HTTPRequestBuilder {
    package static func releases() -> URLRequest {
        let url = URL(string: "https://api.github.com/repos/ChihiroNishioka/genie-in-messages/releases?per_page=100")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("genie-in-messages-update-check", forHTTPHeaderField: "User-Agent")
        return request
    }
}

package struct GitHubReleaseFetcher: ReleaseFetching {
    package let transport: any ReleaseTransport

    package init(transport: any ReleaseTransport) {
        self.transport = transport
    }

    package func fetch() async -> ReleaseFetchResult {
        let response: ReleaseHTTPResponse
        do {
            response = try await transport.send(HTTPRequestBuilder.releases())
        } catch {
            return .failure(.transport, rateLimitReset: nil)
        }

        let reset = resetDate(from: response.headers)
        if response.statusCode == 429 {
            return .failure(.rateLimited, rateLimitReset: reset)
        }
        if response.statusCode == 403, header("x-ratelimit-remaining", in: response.headers) == "0" {
            return .failure(.rateLimited, rateLimitReset: reset)
        }
        guard (200...299).contains(response.statusCode) else {
            return .failure(.http(status: response.statusCode), rateLimitReset: nil)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body),
              let items = object as? [Any] else {
            return .failure(.decode, rateLimitReset: nil)
        }

        let entries = items.compactMap { value -> ReleaseEntry? in
            guard let fields = value as? [String: Any],
                  let tag = fields["tag_name"] as? String,
                  let draft = fields["draft"] as? Bool,
                  let prerelease = fields["prerelease"] as? Bool else { return nil }
            return ReleaseEntry(tag: tag, draft: draft, prerelease: prerelease)
        }
        return .success(entries)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private func resetDate(from headers: [String: String]) -> Date? {
        guard let raw = header("x-ratelimit-reset", in: headers),
              let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
