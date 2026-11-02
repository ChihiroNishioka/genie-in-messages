import Foundation

/// 同じコードのログを、解決するまで重ねない。
package struct NoticeLogGate: Sendable {
    private var unresolved: Set<String> = []

    package init() {}

    /// 解決していないコードなら false。
    package mutating func shouldLog(_ code: String) -> Bool {
        if unresolved.contains(code) { return false }
        unresolved.insert(code)
        return true
    }

    package mutating func resolve(_ codes: Set<String>) {
        unresolved.subtract(codes)
    }
}
