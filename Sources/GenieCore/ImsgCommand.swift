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

    /// imsg 0.19.1 の `send` は本文を `--text` でしか受けない。標準入力も本文ファイルもない。
    /// `--file` は添付であって本文ではない。
    package static func sendArguments(chatID: Int64, text: String) -> [String] {
        ["send", "--chat-id", String(chatID), "--text", text, "--json"]
    }
}
