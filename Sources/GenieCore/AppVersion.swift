import Foundation

public enum AppVersion {
    public static func menuLine(info: [String: Any]?) -> String {
        guard
            let info,
            let version = info["GenieReleaseVersion"] as? String,
            let commit = info["GenieGitCommit"] as? String,
            matches(commit, pattern: "^[0-9a-f]{7}$")
        else {
            return MenuVersion.unknown.line
        }

        if version.isEmpty {
            return MenuVersion.development(commit: commit).line
        }

        guard matches(version, pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$") else {
            return MenuVersion.unknown.line
        }
        return MenuVersion.release(version: version, commit: commit).line
    }

    package static func updateBuild(info: [String: Any]?) -> UpdateBuild {
        guard
            let info,
            let version = info["GenieReleaseVersion"] as? String,
            let commit = info["GenieGitCommit"] as? String,
            matches(commit, pattern: "^[0-9a-f]{7}$")
        else {
            return .unknown
        }

        if version.isEmpty {
            return .development
        }
        guard matches(version, pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$"),
              let parsed = ReleaseVersion(raw: version) else {
            return .unknown
        }
        return .release(parsed)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private enum MenuVersion {
        case release(version: String, commit: String)
        case development(commit: String)
        case unknown

        var line: String {
            switch self {
            case .release(let version, let commit):
                "バージョン: v\(version)（\(commit)）"
            case .development(let commit):
                "バージョン: 開発版（\(commit)）"
            case .unknown:
                "バージョン: 不明"
            }
        }
    }
}
