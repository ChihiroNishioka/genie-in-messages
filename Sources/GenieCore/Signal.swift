import Foundation

/// 合図の判定結果。無害化もこの走査を使う。
struct SignalScan: Equatable {
    /// NFC化した全文。合図に一致したときは接頭辞を除いた残り。
    var remainder: String
    var matched: Bool
}

enum Signal {
    /// NFCのあと、先頭の空白と VS16 を飛ばし、
    /// U+1FA94（🪔）+ 任意の VS16 で始まるかを調べる。
    /// 🧞（U+1F9DE）とその性別の形は合図にしない。
    static func scan(_ text: String) -> SignalScan {
        let normalized = TextNormalizer.nfc(text)
        let scalars = Array(normalized.unicodeScalars)
        var index = 0
        while index < scalars.count, isSkippableLeading(scalars[index]) {
            index += 1
        }
        guard index < scalars.count, scalars[index].value == 0x1FA94 else {
            return SignalScan(remainder: normalized, matched: false)
        }
        index += 1
        if index < scalars.count, scalars[index].value == 0xFE0F {
            index += 1
        }
        let remainder = String(String.UnicodeScalarView(scalars[index...]))
        return SignalScan(remainder: remainder, matched: true)
    }

    static func matches(_ text: String) -> Bool {
        scan(text).matched
    }

    private static func isSkippableLeading(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0xFE0F || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
