import Foundation

package enum OutboundLimits {
    package static let duplicateBodySeconds: TimeInterval = 600
}

enum OutboundStage: String, Codable {
    case reserved
    case markerInFlight = "marker_in_flight"
    case bodyReady = "body_ready"
    case bodyInFlight = "body_in_flight"
    case terminal
}

enum OutboundSelfEvidenceKind: String, Codable {
    case participant
    case selfChatIDs = "self_chat_ids"
}

struct OutboundRecord: Codable, Equatable {
    var id: String
    var sourceHash: String
    var pageHashes: [String]
    var keyHash: String?
    var signature: String
    var target: OutboundTarget?
    var destinationHash: String
    var bodyHash: String
    var selfEvidenceKind: OutboundSelfEvidenceKind?
    var chatID: Int64?
    var createdAt: Date
    var expiresAt: Date
    var stage: OutboundStage
    var terminalCode: String?
    var terminalAt: Date?
    var deadLetterPending: Bool = false
}

struct OutboundLedger: Codable, Equatable {
    static let capacity = 100000
    var sourceHash = ""
    var records: [OutboundRecord] = []
    var count: Int { records.count + records.reduce(0) { $0 + $1.pageHashes.count } }
}
