import Foundation

enum TextNormalizer {
    /// 比較・ハッシュ・判定の前に本文をNFCへ揃える。
    static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }
}
