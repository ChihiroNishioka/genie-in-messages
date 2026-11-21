import Foundation

package enum OutboundTarget: String, Codable, Sendable {
    case family
    case `self`
}

package struct FetchedOutbound: Sendable, Equatable {
    package var pageID: String
    package var idempotencyKey: String?
    package var target: OutboundTarget?
    package var text: String?
    package var createdAt: String
    package var invalidCode: String?

    package init(pageID: String, idempotencyKey: String?, target: OutboundTarget?, text: String?, createdAt: String, invalidCode: String? = nil) {
        self.pageID = pageID
        self.idempotencyKey = idempotencyKey
        self.target = target
        self.text = text
        self.createdAt = createdAt
        self.invalidCode = invalidCode
    }
}

package struct OutboundPage: Sendable {
    package var entries: [FetchedOutbound]
    package var nextCursor: String?

    package init(entries: [FetchedOutbound], nextCursor: String?) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

package protocol OutboundSource: Sendable {
    func prepared(for config: GenieConfig) -> any OutboundSource
    func fetch(cursor: String?, skipping pageIDs: Set<String>, holding heldPageIDs: Set<String>) async throws -> OutboundPage
}

extension OutboundSource {
    package func prepared(for config: GenieConfig) -> any OutboundSource { self }
}

package struct EmptyOutboundSource: OutboundSource {
    package init() {}
    package func fetch(cursor: String?, skipping pageIDs: Set<String>, holding heldPageIDs: Set<String>) async throws -> OutboundPage {
        OutboundPage(entries: [], nextCursor: cursor)
    }
}

enum OutboundHash {
    static func digest(kind: String, values: [String]) -> String {
        let framed = ([kind] + values).map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hex(Data(framed.utf8))
    }
}

enum OutboundCursor {
    static func reconcile(proposed: String?, unhandled: [FetchedOutbound]) -> String? {
        guard let proposed, var cursor = NotionCursor.decode(proposed) else {
            return unhandled.isEmpty ? proposed : nil
        }
        guard !unhandled.isEmpty else { return proposed }
        let pages = Set(unhandled.map { OutboundHash.digest(kind: "page", values: [$0.pageID]) })
        cursor.seen.removeAll { pages.contains($0.id) }
        if let oldest = unhandled.map(\.createdAt).filter({ !$0.isEmpty }).min(), cursor.createdAt > oldest {
            cursor.createdAt = oldest
        }
        cursor.prune()
        return cursor.encoded()
    }
}
