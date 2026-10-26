import Foundation

package struct SendReceipt: Equatable {
    package var id: Int64?
    package var guid: String
    package var status: String

    package init(id: Int64?, guid: String, status: String) {
        self.id = id
        self.guid = guid
        self.status = status
    }
}

package enum SendFailure: Error, Equatable {
    /// AppleScript -1712 / not_started。再送してよい。
    case notStarted
    /// may_have_completed / still_in_flight。再送しない。
    case uncertain
    case failed
}

package enum SendResultParser {
    package static func parse(stdout: String, stderr: String, exitCode: Int32) -> Result<SendReceipt, SendFailure> {
        let payload = lastJSONObject(in: stdout) ?? lastJSONObject(in: stderr)
        if let status = payload?["status"] as? String {
            switch status {
            case "sent":
                if let guid = payload?["guid"] as? String, !guid.isEmpty {
                    return .success(SendReceipt(id: int64(payload?["id"]), guid: guid, status: status))
                }
                return .failure(.uncertain)
            case "not_started":
                return .failure(.notStarted)
            case "may_have_completed", "still_in_flight":
                return .failure(.uncertain)
            default:
                break
            }
        }
        let blob = stdout + "\n" + stderr
        if blob.contains("may_have_completed") || blob.contains("still_in_flight") {
            return .failure(.uncertain)
        }
        if blob.contains("-1712") || blob.contains("not_started") {
            return .failure(.notStarted)
        }
        if exitCode == 0, let guid = payload?["guid"] as? String, !guid.isEmpty {
            return .success(SendReceipt(id: int64(payload?["id"]), guid: guid, status: "sent"))
        }
        return .failure(.failed)
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let int = value as? Int {
            return Int64(int)
        }
        if let int = value as? Int64 {
            return int
        }
        return nil
    }

    private static func lastJSONObject(in text: String) -> [String: Any]? {
        var found: [String: Any]?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            found = object
        }
        return found
    }
}
