import Foundation

private func configuredHTTPSource(for config: GenieConfig, secrets: FileSecretProvider) -> any ReplySource {
    guard let url = EndpointURL.httpsOrLoopback(config.replyFetchURL) else {
        return EmptyReplySource()
    }
    return HTTPReplySource(url: url, secrets: secrets)
}

package struct ConfiguredReplySource: ReplySource {
    package var config: FileConfigProvider
    package var secrets: FileSecretProvider

    package init(config: FileConfigProvider, secrets: FileSecretProvider) {
        self.config = config
        self.secrets = secrets
    }

    package func prepared(for config: GenieConfig) -> any ReplySource {
        if !config.notionDataSourceID.isEmpty {
            return NotionReplySource(
                dataSourceID: config.notionDataSourceID,
                secrets: secrets,
                pageLimit: config.replyPageLimit
            )
        }
        return configuredHTTPSource(for: config, secrets: secrets)
    }

    package func fetch(
        cursor: String?,
        skipping handledReplyIDs: Set<String> = [],
        holding replyIDs: Set<String> = []
    ) async throws -> ReplyPage {
        try await prepared(for: config.load()).fetch(
            cursor: cursor, skipping: handledReplyIDs, holding: replyIDs
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

    package func prepared(for config: GenieConfig) -> any ReplySource {
        configuredHTTPSource(for: config, secrets: secrets)
    }

    package func fetch(
        cursor: String?,
        skipping handledReplyIDs: Set<String> = [],
        holding replyIDs: Set<String> = []
    ) async throws -> ReplyPage {
        try await prepared(for: config.load()).fetch(
            cursor: cursor, skipping: handledReplyIDs, holding: replyIDs
        )
    }
}
