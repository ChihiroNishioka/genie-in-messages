import Foundation
import GenieCore

/// `imsg chats` を1回読んで、解析結果だけを返す。
struct ImsgChatListReader: ChatListReading {
    let config: FileConfigProvider

    func read() async -> ChatListRead {
        let loaded = (try? config.load()) ?? .productDefaults
        let result = await ProcessRunner.run(
            executable: loaded.imsgExecutable,
            arguments: ImsgCommand.chatsArguments(limit: loaded.chatsLimit),
            timeout: loaded.chatsTimeoutSeconds
        )
        if result.exitCode != 0 || result.timedOut {
            return .failed
        }
        return .parsed(ChatListParser.parse(ndjson: result.stdout))
    }
}
