import Foundation

enum ReplyComposer {
    /// 送信直前に、合図を外し、印が無ければ先頭へ付ける。判定は `Signal.scan`。
    static func prepare(body: String, marker: String) -> String {
        let scan = Signal.scan(body)
        var text = scan.matched ? trimLeadingWhitespace(scan.remainder) : scan.remainder
        let markerNFC = TextNormalizer.nfc(marker)
        if markerNFC.isEmpty {
            return text
        }
        if text.hasPrefix(markerNFC) {
            return text
        }
        if text.isEmpty {
            return markerNFC
        }
        let markerEndsWithSpace = markerNFC.unicodeScalars.last.map {
            CharacterSet.whitespacesAndNewlines.contains($0)
        } ?? false
        let textStartsWithSpace = text.unicodeScalars.first.map {
            CharacterSet.whitespacesAndNewlines.contains($0)
        } ?? false
        if markerEndsWithSpace || textStartsWithSpace {
            return markerNFC + text
        }
        return markerNFC + " " + text
    }

    private static func trimLeadingWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
