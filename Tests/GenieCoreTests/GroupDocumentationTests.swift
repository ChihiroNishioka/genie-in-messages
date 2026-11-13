import XCTest

final class GroupDocumentationTests: XCTestCase {
    func testExampleUsesEmptyGroupsAndDefaultReplyMarker() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("config.example.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["group_chat_guids"] as? [String], [])
        XCTAssertEqual(json["reply_marker"] as? String, "🧞‍♂️")
    }

    func testSpecRecordsGroupContractAndDecisions() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        for required in ["### 4.11 設定で許可するグループ", "21. 設定で許可するグループ", "22. 返信の目印", "`group_chat_guids`", "`reply_marker`", "`sender_handle`", "最後の対応先", "各試行の前に", "設定から作る許可表", "メモリ"] {
            XCTAssertTrue(spec.contains(required), required)
        }
    }

    func testReadmeExplainsFamilyGroupsAndReplacesOldMarkerParagraph() throws {
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        let section = try XCTUnwrap(readme.components(separatedBy: "## 家族のグループで使う\n").dropFirst().first)
            .components(separatedBy: "\n## ")[0]
        for required in ["`group_chat_guids`", "`reply_marker`", "`sender_handle`", "Job", "付けない", "一時停止", "設定から消", "解除したあと", "chmod 600", "オーナー", "実機"] {
            XCTAssertTrue(section.contains(required), required)
        }
        XCTAssertFalse(readme.contains("返信の印: 既定は先頭の「🧞‍♂️」で、設定で変えられる。"))
        XCTAssertFalse(readme.contains("印は設定で変えられる（`marker`）"))
        XCTAssertTrue(readme.contains("返信の印: 1通目は `reply_marker`"))
    }
}
