import Foundation

enum TextNormalizer {
    /// 比較・ハッシュ・判定の前に本文をNFCへ揃える。
    static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// ゼロ幅、制御文字、VS16 など、画面に出ない文字。
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .format, .control, .surrogate:
            return true
        default:
            return false
        }
    }

    /// 空白と不可視文字だけなら空とみなす。
    static func isBlank(_ text: String) -> Bool {
        !nfc(text).unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !isInvisible(scalar)
        }
    }
}
