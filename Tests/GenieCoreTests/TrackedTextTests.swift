import XCTest

/// 検査スクリプトが、架空の見本を検出できることを見る。見本は実行時に組み立て、ファイルには置かない。
final class TrackedTextTests: XCTestCase {
    func testCheckerFindsUndashedNotionIDAndNotionTokens() throws {
        let undashed = "0123456789abcdef" + "fedcba9876543210"
        let page = try checkedKinds(of: "https://www.notion.so/\(undashed)")
        XCTAssertTrue(page.contains("notion-id"), page.joined(separator: " "))

        let secretToken = "secret_" + String(repeating: "Aa1", count: 12)
        let secretKinds = try checkedKinds(of: secretToken)
        XCTAssertTrue(secretKinds.contains("token"), secretKinds.joined(separator: " "))

        let ntnToken = "ntn_" + String(repeating: "Bb2", count: 8)
        let ntnKinds = try checkedKinds(of: ntnToken)
        XCTAssertTrue(ntnKinds.contains("token"), ntnKinds.joined(separator: " "))
    }

    private func checkedKinds(of sample: String) throws -> [String] {
        let script = repoRoot().appendingPathComponent("scripts/check-tracked-text.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import importlib.util, sys
spec = importlib.util.spec_from_file_location("check", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(" ".join(sorted(mod.findings_in(sys.stdin.read()))))
""", script.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(sample.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
