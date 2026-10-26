import Foundation

package enum WatchChunk: Equatable {
    case line(String)
    case tooLarge(rowID: Int64?)
}

/// watch の標準出力を行に分ける。1MB を超える行は本文を残さず、rowid だけ探す。
package struct WatchSplitter {
    package static let maxBytes = 1_000_000
    private var buffer = Data()
    private var discarding = false
    private var finder = RowIDFinder()

    package init() {}

    package mutating func append(_ chunk: Data) -> [WatchChunk] {
        var events: [WatchChunk] = []
        for byte in chunk {
            if discarding {
                finder.add(byte)
                if byte == 0x0A {
                    events.append(.tooLarge(rowID: finder.rowID))
                    finder = RowIDFinder()
                    discarding = false
                }
                continue
            }
            if byte == 0x0A {
                if let line = String(data: buffer, encoding: .utf8) {
                    events.append(.line(line))
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if buffer.count >= WatchSplitter.maxBytes {
                finder = RowIDFinder()
                finder.add(buffer)
                finder.add(byte)
                buffer.removeAll(keepingCapacity: false)
                discarding = true
                continue
            }
            buffer.append(byte)
        }
        return events
    }

    /// 改行で終わらなかった末尾も1行として返す。
    package mutating func finish() -> [WatchChunk] {
        if discarding {
            let rowID = finder.rowID
            finder = RowIDFinder()
            discarding = false
            return [.tooLarge(rowID: rowID)]
        }
        guard !buffer.isEmpty else { return [] }
        let line = String(data: buffer, encoding: .utf8)
        buffer.removeAll(keepingCapacity: false)
        if let line { return [.line(line)] }
        return []
    }
}

/// `"id"` の整数を、数字の次が数字以外になるまで確定しない。本文は持たない。
private struct RowIDFinder {
    private enum Phase {
        case seek
        case sawQuote
        case sawI
        case sawD
        case sawKey
        case sawColon
        case digits
    }

    private var phase = Phase.seek
    private var digits = ""
    var rowID: Int64?

    mutating func add(_ data: Data) {
        for byte in data {
            add(byte)
        }
    }

    mutating func add(_ byte: UInt8) {
        guard rowID == nil else { return }
        switch phase {
        case .seek:
            if byte == 0x22 { phase = .sawQuote }
        case .sawQuote:
            phase = byte == 0x69 ? .sawI : (byte == 0x22 ? .sawQuote : .seek)
        case .sawI:
            phase = byte == 0x64 ? .sawD : (byte == 0x22 ? .sawQuote : .seek)
        case .sawD:
            phase = byte == 0x22 ? .sawKey : .seek
        case .sawKey:
            if isSpace(byte) { return }
            if byte == 0x3A {
                phase = .sawColon
            } else {
                phase = byte == 0x22 ? .sawQuote : .seek
            }
        case .sawColon:
            if isSpace(byte) { return }
            if isDigit(byte) {
                digits = String(UnicodeScalar(byte))
                phase = .digits
            } else {
                phase = byte == 0x22 ? .sawQuote : .seek
            }
        case .digits:
            if isDigit(byte) {
                if digits.count >= 18 {
                    digits = ""
                    phase = byte == 0x22 ? .sawQuote : .seek
                    return
                }
                digits.append(Character(UnicodeScalar(byte)))
                return
            }
            if let value = Int64(digits) {
                rowID = value
            }
            digits = ""
            phase = byte == 0x22 ? .sawQuote : .seek
        }
    }

    private func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}

package enum WatchSession {
    package static func shouldStopApplying(_ result: IngestResult) -> Bool {
        switch result {
        case .deferredPaused, .blocked:
            return true
        default:
            return false
        }
    }
}

package enum WatchApply {
    /// 一時停止で保留した行のあと、同じプロセスの続きではカーソルを進めない。
    package static func apply(
        lines: [String],
        ingest: (String) async -> IngestResult
    ) async -> [IngestResult] {
        var applied: [IngestResult] = []
        var stop = false
        for line in lines {
            if stop { break }
            let result = await ingest(line)
            applied.append(result)
            if WatchSession.shouldStopApplying(result) {
                stop = true
            }
        }
        return applied
    }
}
