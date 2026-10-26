import Foundation

package enum LogLevel: String, Codable {
    case info
    case warning
    case error
}

package protocol GenieLog: Sendable {
    func record(level: LogLevel, code: String, chatID: Int64?, guid: String?, rowid: Int64?, detail: String?)
}

extension GenieLog {
    package func record(level: LogLevel, code: String, chatID: Int64?, guid: String?, rowid: Int64?) {
        record(level: level, code: code, chatID: chatID, guid: guid, rowid: rowid, detail: nil)
    }
}

struct LogRecord: Codable, Equatable {
    var ts: String
    var level: String
    var code: String
    var chatID: Int64?
    var guid: String?
    var rowid: Int64?
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case ts, level, code, guid, rowid, detail
        case chatID = "chat_id"
    }
}

package enum LogRedaction {
    /// 標準エラーは最後の1行だけ。空白で分けた単語のうち、宛先・トークン・数字・
    /// ASCII 以外を含むものは単語ごと `[x]` にする。
    package static func tail(_ text: String, maxChars: Int = 120) -> String {
        guard let last = text.split(whereSeparator: \.isNewline).last else { return "" }
        let collapsed = last.split(whereSeparator: \.isWhitespace).map { redactWord(String($0)) }.joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.suffix(maxChars))
    }

    static func redactWord(_ word: String) -> String {
        if word.contains("@") || word.contains("://") || word.contains(";-;") || word.contains(";+;") {
            return "[x]"
        }
        if let separator = word.firstIndex(of: "="), word.index(after: separator) != word.endIndex {
            return "[x]"
        }
        if word.contains(where: \.isNumber) { return "[x]" }
        if word.unicodeScalars.contains(where: { $0.value > 127 }) { return "[x]" }
        return word
    }
}

package final class FileGenieLog: GenieLog, @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let keep: Int
    private let lock = NSLock()
    private let clock: any GenieClock

    package init(url: URL, maxBytes: Int = 5_000_000, keep: Int = 3, clock: any GenieClock = SystemClock()) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
        self.clock = clock
    }

    package func record(level: LogLevel, code: String, chatID: Int64?, guid: String?, rowid: Int64?, detail: String?) {
        let record = LogRecord(
            ts: ISO8601.string(from: clock.now()),
            level: level.rawValue,
            code: code,
            chatID: chatID,
            guid: guid,
            rowid: rowid,
            detail: detail
        )
        guard let line = try? StateCoding.encoder().encode(record) else { return }
        var data = line
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded(incoming: data.count)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [
                    .posixPermissions: NSNumber(value: 0o600),
                ])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = handle.seekToEndOfFile()
            try handle.write(contentsOf: data)
            try FilePermissions.set(url, mode: 0o600)
        } catch {
            return
        }
    }

    private func rotateIfNeeded(incoming: Int) {
        guard keep > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue + incoming > maxBytes else {
            return
        }
        let base = url.path
        let oldest = URL(fileURLWithPath: "\(base).\(keep)")
        if FileManager.default.fileExists(atPath: oldest.path) {
            try? FileManager.default.removeItem(at: oldest)
        }
        if keep > 1 {
            for index in stride(from: keep - 1, through: 1, by: -1) {
                let source = URL(fileURLWithPath: "\(base).\(index)")
                let destination = URL(fileURLWithPath: "\(base).\(index + 1)")
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.moveItem(at: source, to: destination)
                }
            }
        }
        try? FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: "\(base).1"))
    }
}

final class MemoryLog: GenieLog, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [LogRecord] = []

    func record(level: LogLevel, code: String, chatID: Int64?, guid: String?, rowid: Int64?, detail: String?) {
        let record = LogRecord(
            ts: "",
            level: level.rawValue,
            code: code,
            chatID: chatID,
            guid: guid,
            rowid: rowid,
            detail: detail
        )
        lock.lock()
        records.append(record)
        lock.unlock()
    }
}
