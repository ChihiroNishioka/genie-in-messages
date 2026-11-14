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

extension GroupDocumentationTests {
    func testGNSH8JobFamilyContractAndOperationalLimits() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(spec.contains("23. Job 経路の送信者ハンドル"))
        for text in [spec, readme] {
            for required in ["GENIE_GROUP_CHAT_IDS", "GENIE_ALLOWED_CHAT_IDS", "ALLOWED_SOURCE_CHAT_IDS",
                "Job Engine を先に", "オーナーの道具と権限", "member に許す操作", "既定は無効",
                "job_sender_handle_unusable", "256", "家族の管理コマンド", "無視",
                "すべて Job Engine", "メニューだけ", "再試行中", "`/cancel`"] {
                XCTAssertTrue(text.contains(required), required)
            }
            XCTAssertFalse(text.contains("家族のグループは `job_chat_ids` に入れません"))
            XCTAssertFalse(text.contains("家族のグループは `job_chat_ids` に入れない"))
            XCTAssertFalse(text.contains("Job 経路には `sender_handle` を付けない"))
        }
    }

    func testGNSH9MutantsReplaceOldJobExclusion() throws {
        let path = repoRoot().appendingPathComponent("tools/mutants/manifest.json")
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: String]])
        XCTAssertFalse(entries.contains { $0["patch"] == "gc13-job-handle.patch" })
        for name in ["SH-JOB-OMIT", "SH-JOB-EMPTY", "SH-JOB-UNCHECKED", "SH-JOB-MENU", "SH-JOB-SELF", "SH-JOB-STALE", "SH-DOC-OLD"] {
            XCTAssertTrue(entries.contains { $0["name"] == name }, name)
        }
    }

    func testGNSH10PlacesFamilyJobHardwareChecksInSectionNine() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let sectionNine = try XCTUnwrap(spec.components(separatedBy: "## 9. 実機で未確認のこと\n").dropFirst().first)
            .components(separatedBy: "\n## 10. 関連資料")[0]
        let sectionTen = try XCTUnwrap(spec.components(separatedBy: "## 10. 関連資料\n").dropFirst().first)

        for required in ["Job の家族利用", "Routine", "Worker CLI"] {
            XCTAssertTrue(sectionNine.contains(required), "section 9: \(required)")
            XCTAssertFalse(sectionTen.contains(required), "section 10: \(required)")
        }
    }

    func testGNSH11DocumentsJobHandleVisibilityAndHardwareStatus() throws {
        let readme = try readme()
        let section = try XCTUnwrap(readme.components(separatedBy: "## 家族のグループで使う\n").dropFirst().first)
            .components(separatedBy: "\n## 最初の起動")[0]
        let unverified = try XCTUnwrap(section.components(separatedBy: "### Job の家族利用で実機未確認のこと\n").dropFirst().first)
            .components(separatedBy: "\n### ")[0]
        let jobParagraph = try XCTUnwrap(unverified.components(separatedBy: "\n\n").first {
            $0.contains("Job") && $0.contains("実機未確認")
        })

        for required in ["`jobs.sender_handle` にハンドルを保存", "Worker CLI", "標準出力に `sender_handle` の値を出します",
            "Routine は値を結果や通知に書き写しません"] {
            XCTAssertTrue(unverified.contains(required), required)
        }
        XCTAssertTrue(jobParagraph.contains("家族"))

        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let sectionNine = try XCTUnwrap(spec.components(separatedBy: "## 9. 実機で未確認のこと\n").dropFirst().first)
            .components(separatedBy: "\n## 10. 関連資料")[0]
        for required in ["会話記録", "Genie のログ", "Job Engine サーバーの標準出力", "launchd", "deadletter"] {
            XCTAssertTrue(unverified.components(separatedBy: "。").contains {
                $0.contains(required) && $0.contains("未確認")
            }, "README: \(required) remains unverified")
            XCTAssertTrue(sectionNine.components(separatedBy: "\n").contains {
                $0.hasPrefix("- ") && $0.contains(required) && $0.contains("未確認")
            }, "SPEC 9: \(required) remains unverified")
        }
    }

    func testGNSH12DocumentsAllJobStopConsequences() throws {
        let readme = try readme()
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let readmeSection = try XCTUnwrap(readme.components(separatedBy: "## 家族のグループで使う\n").dropFirst().first)
            .components(separatedBy: "\n## 最初の起動")[0]
        let specSection = try XCTUnwrap(spec.components(separatedBy: "### 4.11 設定で許可するグループ\n").dropFirst().first)
            .components(separatedBy: "\n## 5.")[0]
        let stopParagraphs = [readmeSection, specSection].map { section in
            section.components(separatedBy: "\n\n").last {
                $0.contains("job_chat_ids") && $0.contains("外す")
            }
        }

        for (document, paragraph) in zip(["README", "SPEC 4.11"], stopParagraphs) {
            let stop = try XCTUnwrap(paragraph, "\(document) stop paragraph")
            for required in ["通常 webhook", "sender_handle", "正規化", "空文字",
                "GENIE_GROUP_CHAT_IDS", "200", "not_from_me", "webhook_delivered",
                "/cancel", "claimed", "cancel_requested"] {
                XCTAssertTrue(stop.contains(required), "\(document): \(required)")
            }
            XCTAssertTrue(stop.contains("正規化できなければ空文字を送ります"), "\(document): ordinary route fallback")
            XCTAssertTrue(stop.contains("Job Engine で 200 `not_from_me`"), "\(document): disabled family ingress")
            XCTAssertTrue(stop.contains("`webhook_delivered` と記録します"), "\(document): Genie delivery status")
            XCTAssertTrue(stop.contains("claimed のジョブは `/cancel` で `cancel_requested` が立つだけ"), "\(document): claimed cancellation")
            let cancellation = try XCTUnwrap(stop.components(separatedBy: "。").first {
                $0.contains("claimed") && $0.contains("cancel_requested")
            }, "\(document): claimed cancellation sentence")
            XCTAssertTrue(["すぐには止まりません", "すぐには止まらない", "直ちに止まりません", "直ちに止まらない",
                "直ちには止まりません", "直ちには止まらない"].contains {
                cancellation.contains($0)
            }, "\(document): claimed jobs do not stop immediately")
        }
    }

    func testGNSH13ShowsEnablementOrderAndMemberWarningAtStepThree() throws {
        let spec = try String(contentsOf: repoRoot().appendingPathComponent("SPEC.md"), encoding: .utf8)
        let section = try XCTUnwrap(spec.components(separatedBy: "### 4.11 設定で許可するグループ\n").dropFirst().first)
            .components(separatedBy: "\n## 5.")[0]
        let stepThree = try XCTUnwrap(section.components(separatedBy: "\n3. ").dropFirst().first)
            .components(separatedBy: "\n4. ")[0]

        for required in ["Job Engine", "GENIE_GROUP_CHAT_IDS", "job_chat_ids", "member", "Routine", "権限"] {
            XCTAssertTrue(stepThree.contains(required), required)
        }
        let warning = try XCTUnwrap(stepThree.range(of: "member のジョブはオーナーの道具と権限で動きます"))
        let memberPolicy = try XCTUnwrap(stepThree.range(of: "`GENIE_GROUP_CHAT_IDS` を設定する前に"))
        let engine = try XCTUnwrap(stepThree.range(of: "Job Engine を先に更新"))
        let env = try XCTUnwrap(stepThree.range(of: "`GENIE_GROUP_CHAT_IDS`", range: engine.upperBound..<stepThree.endIndex))
        let genie = try XCTUnwrap(stepThree.range(of: "`job_chat_ids`", range: env.upperBound..<stepThree.endIndex))
        XCTAssertLessThan(warning.lowerBound, memberPolicy.lowerBound)
        XCTAssertLessThan(memberPolicy.lowerBound, engine.lowerBound)
        XCTAssertLessThan(engine.lowerBound, env.lowerBound)
        XCTAssertLessThan(env.lowerBound, genie.lowerBound)
    }

    func testGNSH14MovesGc13ExplanationIntoMutantSection() throws {
        let readme = try readme()
        let buildSection = try XCTUnwrap(readme.components(separatedBy: "## 動かし方\n").dropFirst().first)
            .components(separatedBy: "\n## ")[0]
        XCTAssertFalse(buildSection.contains("gc13-job-handle.patch"))
        XCTAssertFalse(buildSection.contains("\n\n\n"))

        let lines = readme.components(separatedBy: "\n")
        let headingIndex = try XCTUnwrap(lines.firstIndex {
            $0.hasPrefix("## ") && ($0.localizedCaseInsensitiveContains("mutant") || $0.contains("壊し方"))
        })
        let nextHeading = lines[(headingIndex + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        let mutantSection = lines[headingIndex..<nextHeading].joined(separator: "\n")
        XCTAssertTrue(mutantSection.contains("gc13-job-handle.patch"))
        XCTAssertTrue(mutantSection.contains("古い期待を置き換えるため廃止"))
    }
}
