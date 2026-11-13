import XCTest
@testable import GenieCore

final class GroupDocumentationTests: XCTestCase {
    private func readme() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
    }

    func testMarkerDocumentsFirstGraphemeEmojiConstraint() throws {
        for file in ["README.md", "SPEC.md"] {
            let text = try String(contentsOf: repoRoot().appendingPathComponent(file), encoding: .utf8)
            for required in ["先頭の書記素", "Emoji_Presentation", "U+FE0F", "🕊", "既定", "reply_marker_invalid"] {
                XCTAssertTrue(text.contains(required), "\(file): \(required)")
            }
        }
    }

    func testReadmeStopsBothPermissionSourcesInOrder() throws {
        let text = try readme()
        let remove = try XCTUnwrap(text.range(of: "1. `group_chat_guids` から対象の guid を消します。"))
        let disable = try XCTUnwrap(text.range(of: "2. メニューでも許可していた場合は、設定から消したあとにメニューのスイッチをオフにします。"))
        XCTAssertLessThan(remove.lowerBound, disable.lowerBound)
        XCTAssertTrue(text.contains("一時的に止めるときは、メニューで全体を一時停止します。"))
    }

    func testReadmePlacesUnverifiedCaveatsNearGroupBehavior() throws {
        let text = try readme()
        let display = try XCTUnwrap(text.components(separatedBy: "設定の行は「グループ（設定）」").dropFirst().first)
            .components(separatedBy: "\n\n")[0]
        XCTAssertTrue(display.contains("macOS の表示とクリック無効は実機未確認"))
        let sender = try XCTUnwrap(text.components(separatedBy: "`sender_handle` を付けます。").dropFirst().first)
            .components(separatedBy: "\n\n")[0]
        XCTAssertTrue(sender.contains("他メンバーの sender の形"))
        XCTAssertTrue(sender.contains("受け側が未知のキーを受け付けるかは実機未確認"))
    }

    func testReadmeContrastsPhoneNumberSeparators() throws {
        XCTAssertTrue(try readme().contains("`+1 555 010 0000` と `+15550100000` は区切りを除くと同じキー"))
    }

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

    func testSpecDescribesConfigLockedMutationsWithoutChangingEitherPermission() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        XCTAssertTrue(spec.contains("設定の行では `setChatEnabled` のオン・オフと `toggleChat` はどちらも許可を変更しない"))
        XCTAssertTrue(spec.contains("`allowlist_off_config_locked` は info、chat_id だけを記録する"))
        XCTAssertFalse(spec.contains("`setChatEnabled(_, enabled: false)` はメニュー側だけを外し"))
    }

    func testSpecStopsBothPermissionSourcesInOrder() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let pause = try XCTUnwrap(spec.range(of: "対象のグループを止めるときは、まず全体を一時停止する。"))
        let remove = try XCTUnwrap(spec.range(of: "次に `group_chat_guids` から対象の guid を消す。"))
        let disable = try XCTUnwrap(spec.range(of: "メニューでも許可していた場合は、設定から消したあとにメニューのスイッチをオフにする。"))
        XCTAssertLessThan(pause.lowerBound, remove.lowerBound)
        XCTAssertLessThan(remove.lowerBound, disable.lowerBound)
        XCTAssertFalse(spec.contains("止めるときは全体を一時停止するか設定から消す"))
    }

    func testSpecDescribesSeparateUnresolvedNoticesAndSnapshotFields() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        for notice in [configGroupNotice(notFound: 1, notGroup: 0), configGroupNotice(notFound: 0, notGroup: 1)] {
            XCTAssertTrue(spec.contains(try XCTUnwrap(notice)))
        }
        for field in ["configChatIDs: [Int64]", "configGroupUnresolved: Int", "configGroupNotFound: Int", "configGroupNotGroup: Int"] {
            XCTAssertTrue(spec.contains("`\(field)`"), field)
        }
        XCTAssertTrue(spec.contains("`configChatIDs` は設定の意思に対応する最後の chat_id"))
        XCTAssertTrue(spec.contains("`configGroupUnresolved` は2種類の未解決件数の合計"))
        XCTAssertFalse(spec.contains("設定のグループ N 件を一覧で確かめられません"))
        XCTAssertFalse(spec.contains("`configGroupUnresolved: Int` のみ"))
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
