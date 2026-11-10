import Foundation

package struct ConfiguredReplySource: ReplySource {
    package var config: FileConfigProvider
    package var secrets: FileSecretProvider

    package init(config: FileConfigProvider, secrets: FileSecretProvider) {
        self.config = config
        self.secrets = secrets
    }

    /// データソース ID があれば Notion を読む。無ければ従来の GET JSON に戻す。
    package func fetch(
        cursor: String?,
        skipping handledReplyIDs: Set<String> = [],
        holding replyIDs: Set<String> = []
    ) async throws -> ReplyPage {
        let loaded = try config.load()
        if !loaded.notionDataSourceID.isEmpty {
            return try await NotionReplySource(
                dataSourceID: loaded.notionDataSourceID,
                secrets: secrets,
                pageLimit: loaded.replyPageLimit
            ).fetch(cursor: cursor, skipping: handledReplyIDs, holding: replyIDs)
        }
        let text = loaded.replyFetchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text) else {
            return ReplyPage(replies: [], nextCursor: cursor)
        }
        return try await HTTPReplySource(url: url, secrets: secrets).fetch(
            cursor: cursor,
            skipping: handledReplyIDs,
            holding: replyIDs
        )
    }
}

package struct ConfiguredHTTPReplySource: ReplySource {
    package var config: FileConfigProvider
    package var secrets: FileSecretProvider

    package init(config: FileConfigProvider, secrets: FileSecretProvider) {
        self.config = config
        self.secrets = secrets
    }

    package func fetch(
        cursor: String?,
        skipping handledReplyIDs: Set<String> = [],
        holding replyIDs: Set<String> = []
    ) async throws -> ReplyPage {
        let loaded = try config.load()
        let text = loaded.replyFetchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text) else {
            return ReplyPage(replies: [], nextCursor: cursor)
        }
        return try await HTTPReplySource(url: url, secrets: secrets).fetch(
            cursor: cursor, skipping: handledReplyIDs, holding: replyIDs
        )
    }
}
