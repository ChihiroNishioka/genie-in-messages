import Foundation
import GenieCore
import ServiceManagement

enum LoginItemController {
    static func statusText() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "オン"
        case .notRegistered:
            return "オフ"
        case .requiresApproval:
            return "承認が必要"
        case .notFound:
            return "見つからない"
        @unknown default:
            return "不明"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

package struct ConfiguredReplySource: ReplySource {
    var config: FileConfigProvider
    var secrets: FileSecretProvider

    /// データソース ID があれば Notion を読む。無ければ従来の GET JSON に戻す。
    package func fetch(cursor: String?) async throws -> ReplyPage {
        let loaded = try config.load()
        if !loaded.notionDataSourceID.isEmpty {
            return try await NotionReplySource(
                dataSourceID: loaded.notionDataSourceID,
                secrets: secrets,
                pageLimit: loaded.replyPageLimit
            ).fetch(cursor: cursor)
        }
        let text = loaded.replyFetchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text) else {
            return ReplyPage(replies: [], nextCursor: cursor)
        }
        return try await HTTPReplySource(url: url, secrets: secrets).fetch(cursor: cursor)
    }
}

package struct ImsgMessageSender: MessageSending {
    var config: FileConfigProvider

    package func send(chatID: Int64, text: String) async throws -> SendReceipt {
        let loaded = try config.load()
        let result = await ProcessRunner.run(
            executable: loaded.imsgExecutable,
            arguments: ImsgCommand.sendArguments(chatID: chatID, text: text),
            timeout: loaded.sendTimeoutSeconds
        )
        return try SendLaunch.interpret(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            timedOut: result.timedOut
        ).get()
    }
}
