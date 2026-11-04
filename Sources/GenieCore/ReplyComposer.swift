import Foundation

enum SplitOutcome: Equatable {
    case send(body: String)
    case emptyBody
    case stillSignal
}

enum ReplyComposer {
    static let markerText = "\u{1F9DE}\u{200D}\u{2642}\u{FE0F}"

    static func split(body: String) -> SplitOutcome {
        let normalized = TextNormalizer.nfc(body)
        var scalars = Array(normalized.unicodeScalars)

        // Keep the existing lamp-prefix sanitization: remove it and its following whitespace.
        var index = 0
        while index < scalars.count,
              CharacterSet.whitespacesAndNewlines.contains(scalars[index])
                || TextNormalizer.isInvisible(scalars[index]) {
            index += 1
        }
        if index < scalars.count, scalars[index].value == 0x1FA94 {
            index += 1
            if index < scalars.count, scalars[index].value == 0xFE0F { index += 1 }
            while index < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
                index += 1
            }
            scalars = Array(scalars.dropFirst(index))
        }

        let genie: [UInt32] = [0x1F9DE, 0x200D, 0x2642]
        var changed = true
        while changed, !scalars.isEmpty {
            changed = false
            while let first = scalars.first,
                  CharacterSet.whitespacesAndNewlines.contains(first) || TextNormalizer.isInvisible(first) {
                scalars.removeFirst()
                changed = true
            }
            if scalars.count >= genie.count,
               Array(scalars.prefix(genie.count)).map(\.value) == genie {
                scalars.removeFirst(genie.count)
                if scalars.first?.value == 0xFE0F { scalars.removeFirst() }
                changed = true
            }
        }

        let result = String(String.UnicodeScalarView(scalars))
        if result.isEmpty { return .emptyBody }
        if Signal.matches(result) { return .stillSignal }
        return .send(body: result)
    }
}
