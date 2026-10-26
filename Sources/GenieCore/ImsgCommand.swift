import Foundation

package enum ImsgCommand {
    /// 子プロセスは libexec の imsg を直接起動する。パスは引数で渡す。
    package static func watchArguments(sinceRowID: Int64) -> [String] {
        var args = ["watch", "--json"]
        if sinceRowID > 0 {
            args.append("--since-rowid")
            args.append(String(sinceRowID))
        }
        return args
    }

    package static func chatsArguments(limit: Int) -> [String] {
        ["chats", "--json", "--limit", String(max(1, limit))]
    }

    package static func sendArguments(chatID: Int64, text: String) -> [String] {
        ["send", "--chat-id", String(chatID), "--text", text, "--json"]
    }
}
