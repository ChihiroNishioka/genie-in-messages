import Foundation

enum SplitOutcome: Equatable {
    case send(body: String)
    case emptyBody
    case stillSignal
}

enum ReplyComposer {
    static let markerText = "\u{1F9DE}\u{200D}\u{2642}\u{FE0F}"

    static func validatedAddressee(_ rawName: String?, sender: String, marker: String) -> String? {
        guard let rawName,
              !rawName.unicodeScalars.contains(where: TextNormalizer.isInvisible),
              !rawName.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { return nil }
        let name = TextNormalizer.nfc(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = name.lowercased()
        let firstGrapheme = name.first
        let startsWithDigit = firstGrapheme?.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) == true
        let startsWithPlus = firstGrapheme?.unicodeScalars.first?.value == 0x2B
        let digitCount = name.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let replyPrefixes = [name, "\(name)へ："]
        guard !TextNormalizer.isBlank(name), name.count <= 20,
              !startsWithDigit, !startsWithPlus, digitCount < 7,
              !name.contains("@"), SenderHandle.normalize(name) == nil,
              !lowercased.hasPrefix("tel:"), !lowercased.hasPrefix("email:"),
              !SelfChat.isHandle(name, sender: sender),
              !replyPrefixes.contains(where: { Signal.matches($0) || isReplyMarker($0, marker: marker) }) else { return nil }
        return name
    }

    static func withAddressee(_ addressee: String?, to body: String) -> String {
        guard let addressee else { return body }
        let prefix = "\(addressee)へ："
        guard !body.hasPrefix(prefix) else { return body }
        return prefix + body
    }

    static func isReplyMarker(_ text: String, marker: String) -> Bool {
        let scalars = Array(TextNormalizer.nfc(text).unicodeScalars.drop(while: {
            CharacterSet.whitespacesAndNewlines.contains($0) || TextNormalizer.isInvisible($0)
        }))
        return markerPrefixes(marker).contains { prefixLength($0, in: scalars) != nil }
    }

    private static func markerPrefixes(_ marker: String) -> [[Unicode.Scalar]] {
        [marker, markerText].map {
            Array(TextNormalizer.nfc($0).unicodeScalars.filter { $0.value != 0xFE0F })
        }.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    private static func prefixLength(_ prefix: [Unicode.Scalar], in text: [Unicode.Scalar]) -> Int? {
        var index = 0
        for scalar in prefix {
            while index < text.count, text[index].value == 0xFE0F { index += 1 }
            guard index < text.count, text[index] == scalar else { return nil }
            index += 1
        }
        while index < text.count, text[index].value == 0xFE0F { index += 1 }
        return index
    }

    static func split(body: String, marker: String = markerText) -> SplitOutcome {
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

        let prefixes = markerPrefixes(marker)
        var changed = true
        while changed, !scalars.isEmpty {
            changed = false
            while let first = scalars.first,
                  CharacterSet.whitespacesAndNewlines.contains(first) || TextNormalizer.isInvisible(first) {
                scalars.removeFirst()
                changed = true
            }
            if let count = prefixes.compactMap({ prefixLength($0, in: scalars) }).first {
                scalars.removeFirst(count)
                changed = true
            }
        }

        let result = String(String.UnicodeScalarView(scalars))
        if result.isEmpty { return .emptyBody }
        if Signal.matches(result) { return .stillSignal }
        return .send(body: result)
    }
}
