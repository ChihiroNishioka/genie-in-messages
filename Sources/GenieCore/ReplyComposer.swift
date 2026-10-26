import Foundation

enum ReplyComposer {
    /// 送信直前に、合図を外し、印が無ければ先頭へ付ける。判定は `Signal.scan`。
    static func prepare(body: String, marker: String) -> String {
        let scan = Signal.scan(body)
        let text = scan.matched ? trimLeadingWhitespace(scan.remainder) : scan.remainder
        let markerNFC = TextNormalizer.nfc(marker)
        let chosen = startsWithSpeechBubble(markerNFC) ? markerNFC : GenieConfig.productDefaults.marker
        if text.hasPrefix(chosen) {
            return text
        }
        if text.isEmpty {
            return chosen
        }
        let chosenEndsWithSpace = chosen.unicodeScalars.last.map {
            CharacterSet.whitespacesAndNewlines.contains($0)
        } ?? false
        let textStartsWithSpace = text.unicodeScalars.first.map {
            CharacterSet.whitespacesAndNewlines.contains($0)
        } ?? false
        if chosenEndsWithSpace || textStartsWithSpace {
            return chosen + text
        }
        return chosen + " " + text
    }

    static func startsWithSpeechBubble(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.drop { scalar in
            scalar.value == 0xFE0F || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        return scalars.first?.value == 0x1F5E8
    }

    private static func trimLeadingWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
