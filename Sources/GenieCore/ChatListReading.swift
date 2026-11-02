import Foundation

/// `imsg chats` を1回実行して解析する。標準出力と標準エラーは返さない。
package protocol ChatListReading: Sendable {
    func read() async -> ChatListRead
}
