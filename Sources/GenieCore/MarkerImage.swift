import Foundation

package protocol MarkerImageLocating: Sendable {
    func markerImageURL() -> URL?
}

package struct StaticMarkerImage: MarkerImageLocating {
    package var url: URL?

    package init(url: URL?) {
        self.url = url
    }

    package func markerImageURL() -> URL? { url }
}

package enum MarkerImageUnavailable: String, Equatable, Sendable {
    case missing
    case empty
    case notRegular = "not_regular"
    case unreadable
    case invalidPath = "invalid_path"
}

package enum MarkerImageCheck: Equatable, Sendable {
    case usable(path: String)
    case unavailable(MarkerImageUnavailable)
}

package enum MarkerImage {
    package static func check(_ url: URL?) -> MarkerImageCheck {
        guard let url else { return .unavailable(.missing) }
        return check(path: url.path)
    }

    package static func check(path: String?) -> MarkerImageCheck {
        guard let path else { return .unavailable(.missing) }
        guard isSafeMarkerImagePath(path) else { return .unavailable(.invalidPath) }

        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return .unavailable(.missing)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .unavailable(.notRegular)
        }
        guard (attributes[.size] as? NSNumber)?.int64Value != 0 else {
            return .unavailable(.empty)
        }
        guard fileManager.isReadableFile(atPath: path) else {
            return .unavailable(.unreadable)
        }
        return .usable(path: path)
    }
}

func isSafeMarkerImagePath(_ path: String) -> Bool {
    guard !path.isEmpty, path.hasPrefix("/") else { return false }
    return !path.unicodeScalars.contains { $0.value <= 0x1F || $0.value == 0x7F }
}
