import Foundation

package struct ConfigPaths: Equatable {
    package var root: URL
    package var logFile: URL

    package var configFile: URL { root.appendingPathComponent("config.json") }
    package var secretFile: URL { root.appendingPathComponent("secret") }
    package var replySecretFile: URL { root.appendingPathComponent("reply-secret") }
    package var allowlistFile: URL { root.appendingPathComponent("allowlist.json") }
    package var stateFile: URL { root.appendingPathComponent("state.json") }
    package var deadLetterFile: URL { root.appendingPathComponent("deadletter.jsonl") }

    package init(root: URL, logFile: URL) {
        self.root = root
        self.logFile = logFile
    }

    package static func `default`(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ConfigPaths {
        let root = home.appendingPathComponent(".config/genie-in-messages", isDirectory: true)
        let logFile: URL
        #if os(macOS)
        logFile = home.appendingPathComponent("Library/Logs/genie-in-messages/genie.log")
        #else
        logFile = root.appendingPathComponent("genie.log")
        #endif
        return ConfigPaths(root: root, logFile: logFile)
    }
}

enum FilePermissions {
    static func mode(of url: URL) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attrs[.posixPermissions] as? NSNumber else {
            throw SecretReadError.unreadable
        }
        return number.uint16Value & 0o777
    }

    static func set(_ url: URL, mode: UInt16) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }
}

package enum ConfigDirectory {
    /// 設定ディレクトリを 0700 で用意し、config.json が無ければ製品既定値を書く。secret は作らない。
    package static func prepare(_ paths: ConfigPaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FilePermissions.set(paths.root, mode: 0o700)
        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            try ConfigLoader.write(.productDefaults, to: paths.configFile)
        }
    }
}

enum SecretReadError: Error, Equatable {
    case missing
    case insecureMode
    case empty
    case unreadable
}

enum SecretFile {
    /// モードが 0600 のときだけトークンを返す。呼び出しのたびに読む。
    static func readToken(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SecretReadError.missing
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw SecretReadError.unreadable
        }
        let mode: UInt16
        do {
            mode = try FilePermissions.mode(of: url)
        } catch {
            throw SecretReadError.unreadable
        }
        guard mode == 0o600 else {
            throw SecretReadError.insecureMode
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SecretReadError.unreadable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SecretReadError.unreadable
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            throw SecretReadError.empty
        }
        return token
    }
}

package protocol SecretProviding: Sendable {
    func webhookSecret() throws -> String
    /// ファイルが無ければ nil。モードが 0600 でなければ投げる。
    func replySecret() throws -> String?
}

package struct FileConfigProvider: ConfigProviding, Sendable {
    package var url: URL

    package init(url: URL) {
        self.url = url
    }

    package func load() throws -> GenieConfig {
        try ConfigLoader.load(from: url)
    }
}

package struct FileSecretProvider: SecretProviding {
    package var paths: ConfigPaths

    package init(paths: ConfigPaths) {
        self.paths = paths
    }

    package func webhookSecret() throws -> String {
        try SecretFile.readToken(at: paths.secretFile)
    }

    package func replySecret() throws -> String? {
        if !FileManager.default.fileExists(atPath: paths.replySecretFile.path) {
            return nil
        }
        return try SecretFile.readToken(at: paths.replySecretFile)
    }
}

struct StaticSecret: SecretProviding, Sendable {
    var webhook: String
    var reply: String?
    func webhookSecret() throws -> String { webhook }
    func replySecret() throws -> String? { reply }
}
