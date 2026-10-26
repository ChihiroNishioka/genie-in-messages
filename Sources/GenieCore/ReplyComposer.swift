import Foundation

enum ReplyComposer {
    /// 送信直前に、合図を外し、印が無ければ先頭へ付ける。判定は `Signal.scan`。
    static func prepare(body: String, marker: String) -> String {
        let scan = Signal.scan(body)
        let text = scan.matched ? trimLeadingWhitespace(scan.remainder) : scan.remainder
        let markerNFC = TextNormalizer.nfc(marker)
        let chosen = Signal.matches(markerNFC) ? GenieConfig.productDefaults.marker : markerNFC
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

    private static func trimLeadingWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
