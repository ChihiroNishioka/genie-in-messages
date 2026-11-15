# 1通目を GIF にする（開発要件・仕様・受け入れテスト）

対象: `feat/gif-marker`（基点 v1.2.0 / 75a37d1）。オーナーの OK 済み（2026-11-15 01:56 JST）。
この文書だけを見て、テストと実装を書けるようにする。マージ、Mac mini の操作、実送信、公証はこの作業に入れない。

## 0. 一言で

返事は今どおり2通。1通目を、文字の `reply_marker`（既定 🧞‍♂️）だけの1通から、同梱のアニメ GIF 画像だけの1通に変える。
GIF が使えないとき、または「届いていないと分かっている失敗」のときだけ、同じ試みの中で今までの文字の `reply_marker` にフォールバックする。
2通目、送り直しの規則、レート、ループ防止（sentGUIDs、指紋、isReplyMarker、🪔）、partial_replies の再開は変えない。

## 1. 用語

| 語 | 意味 |
|---|---|
| 画像1通目 | `imsg send --chat-id <id> --file <path> --json` で送る、GIF だけの1通 |
| 文字1通目 | 今までの `imsg send --chat-id <id> --text <reply_marker> --json` |
| フォールバック | 画像1通目をやめ、同じ試みの中で文字1通目を送ること |
| 試み | `sendMarker` の1回の呼び出し。保留からの再試行は別の試み |
| 使える GIF | 4.2 の検査に通ったファイル |

## 2. 送信の契約（決定事項）

1. 画像送信が成功し、空でない guid が返ったら、その回の1通目として文字の marker は送らない。
2. 画像送信が `SendFailure.failed`（届いていないと分かっている失敗。`SendFailure` 以外の throw も今どおり `.failed` 扱い）なら、同じ試みの中で `config.replyMarker` の文字1通にフォールバックする。カスタムの `reply_marker` を無視して 🧞‍♂️ に固定しない。文字側の結果（成功・失敗・保留・結果不明）の扱いは、今の `sendMarker` の成功処理と `handleMarkerFailure` と同じにする。
3. 画像送信が結果不明（`.uncertain`。タイムアウト、`status: sent` だが guid が無い、-1712 だけで `not_started` が無い、を含む）なら、フォールバックしない。今の1通目の結果不明と同じに扱う（`send_uncertain` の deadletter、処理済み、レートは戻さない、2通目は送らない、送り直さない）。
   - 理由: GIF が実は届いている恐れがある。文字を足すと GIF と絵文字の両方が届く。安全側に倒し、何も足さない。
4. 画像送信が `.notStarted`（-1712 と `not_started`、起動できなかった）なら、その場ではフォールバックしない。今の1通目の `.notStarted` と同じ保留（`apple_event_1712`、レートを戻す、意図を戻す、保留して再試行）にする。再試行は新しい試みなので、そのとき GIF が使えれば画像から試し、使えなければ文字にする。
5. 同梱の GIF が見つからない、サイズ0、通常ファイルでない、読めない、パスが使えない形のときは、画像送信を起動せずに文字1通目を送る（中身は今の文字1通目そのもの）。
6. 2通目は今のまま（ReplyComposer、グループの呼び名、本文だけ最大1回の送り直し、レートは1通目の前だけ、1通目は届いたあとは送り直さない）。
7. 画像1通目が返した guid も `sentGUIDs` に入れる。`partial_replies.marker_guid` にも、その guid を入れる（文字1通目のときと同じ使い方）。
8. 指紋：画像1通目には指紋を付けない（送っていない絵文字のハッシュを記録しない）。文字フォールバックの指紋は今どおり `config.replyMarker` のハッシュ。画像のループ防止は `sentGUIDs` が主になる。
9. `ReplyComposer.isReplyMarker` と 🪔 の判定（`Signal.matches`）は変えない。画像だけの受信は本文が 🪔 で始まらないので合図にならない。
10. `reply_marker` の設定、検証、`reply_marker_invalid` の警告、受信での目印の無視は残す（文字フォールバックと受信の判定で使う）。

入れないもの: GIF の再エンコード・リサイズ・差し替え、🪔 の変更、`reply_marker` 設定の廃止、本文への GIF 埋め込み、1通にまとめること、新しい設定キー、メニューの新しい表示、実送信。

## 3. 資産（GIF）

- 原本: `/workspace/dev/genie-runs/reply-marker-source.gif`（オーナー作。100×100、GIF89a、65580 バイト、sha256 `fc645a3d14b4add061ad9fd92105cab7aa767f46a4e43d500c702d3fe9efcd3c`）。
- リポジトリでの置き場所: `AppBundle/ReplyMarker/reply-marker.gif`。原本をバイト単位でそのままコピーする（`cp` のみ。画像ツールを通さない）。
- 承認したハッシュはテストの外に置く（LESSONS）。`Tests/GenieCoreTests/Fixtures/approved-hashes.txt` に1行足す:
  `fc645a3d14b4add061ad9fd92105cab7aa767f46a4e43d500c702d3fe9efcd3c  AppBundle/ReplyMarker/reply-marker.gif`
  既存の `LampIconTests.testApprovedBytesMatchTheFrozenHashes` は、この表の全行を検査するので、そのまま GIF も見る。
- `scripts/assemble-app.sh` の `stage_app` が `Contents/Resources/ReplyMarker/` を作り、`AppBundle/ReplyMarker/reply-marker.gif` をコピーする。MenuLamp のコピーは変えない。
- `.gif` は `scripts/check-tracked-text.py` の対象外（既に SKIP）。Package.swift の変更は不要（AppBundle はターゲット外）。

## 4. 設計

### 4.1 GIF の場所を渡す口

`Sources/GenieCore`（新規ファイル例: `MarkerImage.swift`）に置く。

```swift
package protocol MarkerImageLocating: Sendable {
    /// 同梱 GIF の場所。無ければ nil。1通目の試みのたびに呼ぶ。
    func markerImageURL() -> URL?
}
package struct StaticMarkerImage: MarkerImageLocating {   // テストと差し込み用
    package var url: URL?
    package init(url: URL?)
    package func markerImageURL() -> URL? { url }
}
```

- `GenieEngine.init` に `markerImage: any MarkerImageLocating` を足す。**既定値を付けない。** `GenieEngine(` の生成箇所をすべて検索し（本番の `GenieController`、Harness の `makeEngine`、テストの直接生成を含む。列挙は漏れ得るので列挙だけに頼らない）、漏れなく明示して渡す。文字フォールバックを主題にするテスト以外は、使える GIF の locator を渡す（Harness の既定）。列挙から漏れた箇所を nil にして画像経路を迂回しない。既定値で黙って文字経路に落ちるテストを作らないため。
- 本番（`Sources/GenieMenuBar`）は `BundledMarkerImage` を作り、`Bundle.main.url(forResource: "reply-marker", withExtension: "gif", subdirectory: "ReplyMarker")` だけを返す。`LampIcon` のような `#filePath`（ソースの場所）への代わりの道は**作らない**。バンドルに無ければ nil で、文字フォールバックになる。`GenieController` が `GenieEngine` に渡す。
- 場所の問い合わせと検査は、試みのたびに行う（直したファイルが次の試みから使われる。再試行でも決め直す）。

### 4.2 GIF の検査

```swift
package enum MarkerImageUnavailable: String, Equatable, Sendable {
    case missing        // nil、存在しない
    case empty          // サイズ 0
    case notRegular = "not_regular"   // ディレクトリ、シンボリックリンク、FIFO など
    case unreadable     // 読めない
    case invalidPath = "invalid_path" // 空、相対、NUL や制御文字を含む
}
package enum MarkerImageCheck: Equatable, Sendable {
    case usable(path: String)
    case unavailable(MarkerImageUnavailable)
}
package enum MarkerImage {
    package static func check(_ url: URL?) -> MarkerImageCheck
}
```

判定順（最初に当たったもの）:

1. `url` が nil → `missing`
2. `url.path` が空、`/` で始まらない、U+0000〜U+001F か U+007F を含む → `invalidPath`
3. リンクをたどらない属性（`FileManager.attributesOfItem(atPath:)` は lstat 相当）が取れない（ENOENT など）→ `missing`
4. `FileAttributeType` が `.typeRegular` でない（シンボリックリンクも含む）→ `notRegular`
5. サイズが 0 → `empty`
6. `FileManager.isReadableFile(atPath:)` が false → `unreadable`
7. それ以外 → `usable(path: url.path)`

- 絶対パスに限るので、引数の要素が `-` で始まることは無い。名前の途中の空白や `-`、`--text` のような部分は許す（引数配列の1要素なので注入にならない）。
- GIF の中身（マジックやハッシュ）は送信時には確かめない（残した判断。7章）。資産の正しさはテストで固定する。

### 4.3 imsg の引数

`ImsgCommand` に足す。既存の `sendArguments` とコメント（「`--file` は添付であって本文ではない」）は変えない。

```swift
/// 画像だけの1通。`--text` は付けない。パスは1要素で渡す。
/// 使えないパス（空、相対、制御文字）は nil を返し、起動させない。
package static func sendFileArguments(chatID: Int64, path: String) -> [String]? {
    // 4.2 の 2 と同じ条件で nil
    ["send", "--chat-id", String(chatID), "--file", path, "--json"]
}
```

- シェル、`osascript`、`/bin/sh`、結合したコマンド文字列は使わない。`Process.executableURL` と `arguments` 配列だけ（`ProcessRunner.run`）。
- 実行ファイルは今と同じ `config.imsgExecutable`（libexec の imsg）。

### 4.4 送信の契約（MessageSending）

```swift
package protocol MessageSending: Sendable {
    func send(chatID: Int64, text: String) async throws -> SendReceipt
    func sendFile(chatID: Int64, path: String) async throws -> SendReceipt
}
```

- プロトコル拡張で `sendFile` の既定実装を**付けない**（付けると、実装を忘れた送信者が黙ってフォールバックし、テストだけの道になる）。
- `ImsgMessageSender.sendFile`:
  1. `config.load()`
  2. `guard let arguments = ImsgCommand.sendFileArguments(...) else { throw SendFailure.failed }`（起動しない。届いていないと分かっているのでフォールバックになる）
  3. `ProcessRunner.run(executable: loaded.imsgExecutable, arguments: arguments, timeout: loaded.sendTimeoutSeconds)`
  4. `SendLaunch.interpret(...)` をそのまま使う（タイムアウトは `.uncertain`、起動失敗は `.notStarted`）。結果の読み方は `send` と共通。
- `SendResultParser` と `SendLaunch` は変えない。

### 4.5 Engine の1通目（`sendMarker`）

今の `sendMarker` の前半（一時停止・停止、許可、guid の照合、ロック、レートの確認）は変えない。レートの枠を確かめたあと、意図を記録する前に、GIF を決める。

```
check = MarkerImage.check(markerImage.markerImageURL())
reservedAt = now; countRate(reservedAt)                // 返事1件で1回。フォールバックでも数え直さない
if check == .usable(path):
    noticeLog.resolve(["marker_image_unavailable"])
    recordIntent(kind: .image, at: reservedAt, part: .marker)   // hash は "" 、指紋は足さない
    persist / 一時停止 / 許可 / guid の確認（今と同じ3段。失敗時の戻し方も今と同じ）
    result = sender.sendFile(chatID, path)
    DB 世代が変わった → 今と同じ（成功なら guid を sentGUIDs、意図を終える、処理済み、reply_dropped_db_reset detail "marker"）
    成功・guid あり → 文字の成功と同じ処理（sentGUIDs、partial_replies、persist、reply_sent detail "marker_image"、sendBody）
    成功・guid 空 → handleMarkerFailure(.uncertain, detail "marker_image")
    .uncertain   → handleMarkerFailure(.uncertain, detail "marker_image")
    .notStarted  → handleMarkerFailure(.notStarted, detail "marker_image")
    .failed      → warning "marker_image_failed" を1件記録
                   rollbackIntent（画像の意図だけ。レートの予約は残す）
                   → 文字フォールバックへ（下）
else (.unavailable(reason)):
    if noticeLog.shouldLog("marker_image_unavailable") { warning, detail = reason.rawValue }
    → 文字フォールバックへ（下）

文字フォールバック（今の文字1通目と同じ）:
    recordIntent(kind: .text, text: config.replyMarker, at: reservedAt, part: .marker)  // 指紋も今どおり
    persist / 一時停止 / 許可 / guid の確認（今と同じ3段。失敗時はレートを戻し、意図を戻し、今と同じ保留・処理済み）
    DB 世代の確認
    result = sender.send(chatID, config.replyMarker)
    以降は今と同じ（成功 → reply_sent detail "marker"、sendBody / 失敗 → handleMarkerFailure(detail "marker")）
```

要点:

- 画像の `.failed` のあとに文字を送る前にも、一時停止・停止、許可、guid の照合を確かめ直す。止まっていれば文字は送らず、レートを戻して1通目を保留する（今の「送る直前に止まっていた」と同じ）。再試行は画像から。
- 文字の意図は画像と同じ `reservedAt` で記録する。`handleMarkerFailure` の `.notStarted` と `.failed` が `pending.at` でレートを戻すので、予約1件がちょうど戻る。
- `attempts` はフォールバックで増やさない（同じ試み）。
- `handleMarkerFailure` にログの `detail` を渡せるようにする（既定 `"marker"`）。deadletter の `error`（`send_failed`、`send_uncertain`）と `lastError` は今と同じ文字列。
- 画像のフォールバックでは `lastError` を変えない（その後の文字や本文の結果で今どおり決まる）。メニューは変えない。
- ロックの確認は1回だけ（画像の前）。フォールバックの文字がロックで -1712 になれば、今どおり保留。

### 4.6 state

`PendingSend` に任意の欄を足す。

```swift
enum MarkerKind: String, Codable { case text, image }
var markerKind: MarkerKind?    // CodingKey "marker_kind"。無い（古い state）なら text とみなす
```

- 画像の意図は `hash: ""`、`marker_kind: "image"`、`part: "marker"`。`fingerprints` には何も足さない。
- `recordIntent` は kind を受け取り、画像なら指紋を足さない。`rollbackIntent` は今のままでよい（一致する指紋が無いだけ）。
- `settleInterrupted`（起動時の途中で落ちた送信）は、`hash` が空なら指紋を足さない。それ以外は今どおり（`send_interrupted` の deadletter、処理済み、2通目は送らない、レートの扱い）。
- `PartialReply` は変えない。`marker_guid` に画像の guid が入る。
- 古い版（v1.2.0）へ戻したとき、`marker_kind` は無視され、`hash: ""` の指紋が1件足されるだけ（どの受信にも一致しない）。

### 4.7 ループ防止

- 受信の判定順は変えない（edited/unsent、タップバック、送信済み guid、処理済み guid、指紋、目印、🪔）。
- 画像1通目の guid は `sentGUIDs` に入るので、watch に戻ってきた自分の画像は `ignoredSentGUID`。
- guid が取れなかった画像（結果不明）が戻ってきても、本文が 🪔 で始まらないので `ignoredNoSignal`。webhook には渡らない。
- 指紋は、文字1通目と2通目にだけ付く。画像の1通目には付かない。

### 4.8 ログ

値（パス、本文、guid 以外の識別子）は出さない。パスにはユーザー名が入るので、detail にも出さない。

| code | level | detail | いつ |
|---|---|---|---|
| `marker_image_unavailable` | warning | `missing` / `empty` / `not_regular` / `unreadable` / `invalid_path` | GIF が使えず文字にしたとき。`NoticeLogGate` で続くあいだ1回。使える GIF を確かめたときに resolve し、また起きたらもう1回 |
| `marker_image_failed` | warning | なし | 画像送信が `.failed` で文字にしたとき（1回ごと） |
| `reply_sent` | info | `marker_image` | 画像1通目が届いた |
| `reply_sent` | info | `marker` | 文字1通目が届いた（今どおり） |
| `send_uncertain` / `apple_event_1712` | error | `marker_image` | 画像1通目の結果不明・保留 |

### 4.9 テストの道具（Harness / FakeSender）

```swift
enum FakeOutgoing: Equatable { case text(String); case file(String) }

final class FakeSender: MessageSending, @unchecked Sendable {
    /// 文字と画像をまたいで、呼ばれた順に1つずつ使う。
    var script: [Result<SendReceipt, SendFailure>] = []
    /// 次の send / sendFile で、SendFailure 以外の Error を1回投げる（契約2の「それ以外の throw も .failed」を見る）。
    var throwNext: Error?
    /// 呼ばれた順のすべて。
    var outgoing: [(chatID: Int64, item: FakeOutgoing)] = []
    /// 文字だけ（今の `sent` と同じ形）。
    var sent: [(chatID: Int64, text: String)] = []
    /// 画像だけ。
    var sentFiles: [(chatID: Int64, path: String)] = []
    var onSend: (() async -> Void)?        // 両方で呼ぶ
    var onSendFile: (() async -> Void)?    // 画像だけで呼ぶ（任意）
}
```

- 既定の受領は `SendReceipt(id: outgoing.count, guid: "sent-\(outgoing.count)", status: "sent")`（数は種類をまたぐ）。画像成功が1通目なら marker の guid は今と同じ `sent-1`。
- `sendFile` は `.text` に化けさせない。画像を文字 `M` として記録するような細工はしない。
- Harness に `var markerImage: any MarkerImageLocating = StaticMarkerImage(url: repoRoot().appendingPathComponent("AppBundle/ReplyMarker/reply-marker.gif"))` を足し、`makeEngine` で渡す。**既定は画像が使える本番の道**。
- 欠損などのフィクスチャは、テストの中で一時ディレクトリに作る（空ファイル、ディレクトリ、シンボリックリンク、存在しないパス）。`unreadable` は `chmod 000` で作り、root で動くときは `XCTSkip`。
- 入口は今と同じ `pollReplies()` / `retryHolds()` / `ingestWatchLine` / `GeniePoller.tick()`。テストのためだけの送信関数は作らない。時計は `h.clock` を進め、sleep しない。

### 4.10 既存テストの移し方

`grep -rn "sender\.sent\|sender\.script" Tests` で約300か所。次の規則で直す。

1. **文字の目印そのものが主題のテスト**は、文字フォールバックを本番の道として通す。`h.markerImage = StaticMarkerImage(url: nil)`（同梱 GIF が無い本番と同じ）を明示し、名前かコメントに「文字フォールバック」と書く。少なくとも次:
   - `SplitReplyTests.testFirstMessageIsExactlyTheFourScalars`（変異 SPLIT1 の対象）
   - `GroupPrivacyRegressionTests.testConfiguredMarkerAlsoAppliesToSelfChatAndFingerprint`（変異 GC16-FINGERPRINT の対象）
   - カスタムの `reply_marker` が1通目に出ることを見るテスト（GroupMarkerTests、GroupPrivacyRegressionTests などで `sent.map(\.text)` の先頭に目印を期待するもの）
   - 目印の指紋で echo を無視することを見るテスト（EngineWatchTests など）
2. **それ以外**（順序、保留、再起動、上限、レート、照合、グループの呼び名など）は画像が既定のまま。期待の `[M, B]` を `outgoing.map(\.item) == [.file(gif), .text(B)]` か、`sentFiles.count` と `sent.map(\.text) == [B]` に直す。script の中身は変えなくてよい（種類をまたいで順に使うため、1通目の結果は画像に効く）。
3. 期待を消して通すことはしない。各テストの主張（何通、どの順、保留か処理済みか、レートの数）は保つ。
4. 文字1通目の失敗を見ていたテスト（`testMarkerFailedSendsNoBody` など）は、画像が既定だと `.failed` がフォールバックになり意味が変わる。規則 1 で文字経路に移すか、画像では「画像 failed → 文字 failed」を script に書く。どちらにしたかをテスト名で分かるようにする。
5. 「何も送らない」の確認は、`sent.count == 0` ではなく `outgoing`（必要なら `sentFiles` も）で行う。`sent` は文字だけなので、画像送信を見落とす（StartupSendTests など）。
6. `onSend` で `sent.count` を見て止め・保存・ロックする同期は、`outgoing` の件数と種類（`.file` / `.text`）で同じタイミングを保つ。画像の1通目のあとに発火させたい処理は `onSendFile`、または `outgoing` の先頭が `.file` になったときを見る。文字送信を前提にしていた「1通目のあと」は、画像既定のテストでは画像の1通目のあとに揃える。
7. 変異パッチは文脈の行を含む。`sendMarker`・`recordIntent`・`settleInterrupted`・README の「返信の印」の行・`ImsgCommand` を変えると当たらなくなるものがある。全部 `git apply --check` が通るように、パッチ側を新しい文脈に直す（壊し方の意味は変えない）。少なくとも次を見る: split1 / split3 / split12 / split22 / split37 / split41 / split42 / split43、gc01 / gc02 / gc08 / gc16-marker-fingerprint / gc16-ignore-configured-marker / gc18-custom-ingest / gc21-ignore-sent-guid / gc20-shell-command、fix3-paused-config-no-recovery、gc24-restore-old-marker-paragraph、fix1-doc-marker、split15 / split25 / split28 / split29 / job16a（StateStore）、macos-assemble-omit-images。

### 4.11 文書

README:
- 「方針」の行 `- 返信の印: 1通目は `reply_marker`（既定 🧞‍♂️）だけ、…` を次に置き換える:
  `- 返信の印: 1通目は同梱の GIF 画像だけ、2通目は本文だけ。GIF が無い・空・送信がはっきり失敗したときは、同じ回に `reply_marker`（既定 🧞‍♂️）の文字1通にする。結果不明のときは文字を足さない。グループでは安全な設定済みの呼び名を本文の先頭に付ける。古い `marker` は読み飛ばす。設定の目印と既定の 🧞‍♂️ で始まる受信は無視する。詳しくは `SPEC.md` の 4.4、4.9、4.11、決定 22、24。`
- 送信の説明（`--text` の段落）に、画像は `imsg send --chat-id <id> --file <path> --json` で `--text` を付けないこと、`--file` は添付で本文ではないこと、を1文足す。
- 実機未確認（6章の4点）を README にも短く書く。
- `reply_marker` の段落（4.9 の書記素の制約）は残す（GroupDocumentationTests と GF1-DOC-MARKER が見ている）。

SPEC:
- 冒頭の「最終更新」を 2026-11-15 にし、1通目の GIF（4.4、決定 24）を書く。
- 2章の表「返信の印」の行を新しい1通目に直す。
- 4.1 の送信の行と「本文の渡し方」に、画像は `--file <path>`（`--text` なし、引数配列の1要素）と書く。「`--file` は添付」の文は残す。
- 4.4 の 120・121 行を直す（1通目は同梱 GIF だけ、フォールバックの条件、結果不明と -1712 の扱い）。128・129 行に画像の結果を足す。135 行に「画像1通目の guid も記録する」、136 行に「画像1通目には指紋を付けない。文字フォールバックの指紋は今どおり」を足す。
- 4.3 の `partial_replies` の行に「`marker_guid` は画像でも文字でもその guid」と足す。`pending_sends` の `marker_kind` を書く。
- 4.11 の「送信は `Process.executableURL` と引数配列のまま」に画像のパスを足す。手順 1 の「印と本文が2通で届く」を「GIF と本文」に直す。
- 7章に決定 24 を足す（決定 20・22 の本文は変えない）:
  `24. 1通目の GIF（2026-11-15、オーナーの OK）。決定 20・22 の「1通目は reply_marker だけ」を改める。1通目は同梱のアニメ GIF だけの1通で、imsg send --chat-id <id> --file <path> --json（--text なし）で送る。GIF が無い・空・通常ファイルでない・読めないとき、または送信が届いていないと分かっている失敗のときは、同じ試みの中で reply_marker の文字1通にする。結果不明では文字を足さず、2通目も送らない。-1712 は保留し、再試行では GIF から試す。画像の guid は送信済み guid に入れ、指紋は付けない。reply_marker の設定、受信での目印の無視、🪔 の合図、2通目と送り直しの規則、レートは変えない。`
  （実際の文では `reply_marker` などをバッククォートで囲む）
- 9章に6章の項目を足す。

LESSONS（任意）: 「1通目は GIF。結果不明は足さない。`GifMarkerTests` と変異 GIF-* が守る」の1段落。

### 4.12 壊し方（tools/mutants）

Linux 用の変異（下表の12個）だけを `tools/mutants/manifest.json` に足す（`filter` は 5章の確認方法のテスト）。macOS 専用の assemble 変異は manifest に入れない（Linux の `check-mutants.py` がベースライン実行数不足で失敗する）。`tools/run-mutants.sh` の macOS `filter_for` にだけ足す。

| name | patch | 壊し方 | 落ちるテスト |
|---|---|---|---|
| GIF-UNCERTAIN-FALLBACK | gif-uncertain-fallback.patch | 画像の `.uncertain` でも文字へフォールバックする | GifMarkerTests.testImageUncertainSendsNothingMore |
| GIF-NOTSTARTED-FALLBACK | gif-notstarted-fallback.patch | 画像の `.notStarted` で、その場で文字へフォールバックする | GifMarkerTests.testImageNotStartedHoldsAndRetriesImageFirst |
| GIF-RETRY-TEXT | gif-retry-text.patch | 保留からの再試行では画像を試さず文字にする | GifMarkerTests.testImageNotStartedHoldsAndRetriesImageFirst |
| GIF-SUCCESS-ALSO-TEXT | gif-success-also-text.patch | 画像成功のあとにも文字の目印を送る | GifMarkerTests.testImageSuccessSendsNoTextMarker |
| GIF-NO-FALLBACK | gif-no-fallback.patch | 画像の `.failed` のあと文字へフォールバックしない | GifMarkerTests.testImageFailedFallsBackToMarkerAndContinues |
| GIF-DEFAULT-MARKER | gif-default-marker.patch | フォールバックで `ReplyComposer.markerText` を送る | GifMarkerTests.testImageFailedFallsBackToConfiguredMarker |
| GIF-NO-SENTGUID | gif-no-sentguid.patch | 画像の guid を `sentGUIDs` に入れない | GifMarkerTests.testImageGuidIsIgnoredWhenWatchEchoesIt |
| GIF-FINGERPRINT | gif-fingerprint.patch | 画像の意図に `config.replyMarker` のハッシュと指紋を付ける | GifMarkerTests.testImageMarkerAddsNoEmojiFingerprint |
| GIF-ACCEPT-DIRECTORY | gif-accept-directory.patch | 検査で通常ファイルの確認を外す | GifMarkerTests.testUnavailableImageFallsBackWithoutLaunching |
| GIF-FILE-TEXT-FLAG | gif-file-text-flag.patch | `sendFileArguments` に `--text`, `""` を足す | GifMarkerTests.testFileArgumentsAreLiteralAndHaveNoText |
| GIF-FILE-SHELL | gif-file-shell.patch | `sendFileArguments` を `/bin/sh -c` の結合文字列にする | GifMarkerTests.testFileArgumentsAreLiteralAndHaveNoText |
| GIF-DOC-OLD | gif-doc-old.patch | README の「返信の印」を旧文に戻す | GroupDocumentationTests.testReadmeExplainsFamilyGroupsAndReplacesOldMarkerParagraph |
| （macOS）| macos-assemble-omit-gif.patch | assemble で GIF をコピーしない | LampIconTests.testAssembleCopiesReplyMarkerGif |

最低1つは必須（LESSONS）。Linux の12個を manifest に入れることを求める。どれも `python3 tools/check-mutants.py` で `KILLED`（アサーション失敗）になること。macOS の assemble 変異は `tools/run-mutants.sh macos` だけで走らせる。

## 5. 受け入れテスト（GREEN when）

新しいテストは主に `Tests/GenieCoreTests/GifMarkerTests.swift`（クラス `GifMarkerTests`）に置く。`gif` は Harness の既定 GIF の絶対パス、`M` は 🧞‍♂️、`B` は「こんにちは」。区分の「新規」は v1.2.0 で落ちる（またはコンパイルできない）、「回帰」は今も通る性質を新しい道でも保つ。

### 5.1 資産・組み立て

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| A1 | 新規 | リポジトリの `AppBundle/ReplyMarker/reply-marker.gif` を読む | 65580 バイト、先頭6バイトが `GIF89a`、バイト6〜9が `64 00 64 00`（100×100）、sha256 が approved-hashes.txt の値（`fc645a3d…efcd3c`）と一致 | `GifMarkerTests.testBundledGifIsTheApprovedOriginal`、`LampIconTests.testApprovedBytesMatchTheFrozenHashes` |
| A2 | 新規（macOS） | `scripts/assemble-app.sh --stage-only <tmp>.app` | `Contents/Resources/ReplyMarker/reply-marker.gif` があり、sha256 が承認値と一致。MenuLamp と AppIcon は今どおり | `LampIconTests.testAssembleCopiesReplyMarkerGif`（`#if os(macOS)`）、変異 macos-assemble-omit-gif |

### 5.2 引数（注入なし）

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| B1 | 新規 | `sendFileArguments(chatID: 7, path: "/tmp/a b/-x --text y.gif")` | `["send","--chat-id","7","--file","/tmp/a b/-x --text y.gif","--json"]`、要素数6、`--text` を含まない、5番目がパスそのもの。同じ配列を `ProcessRunner.run(executable: "/bin/echo", …)` に渡すと、標準出力が要素を空白でつないだもの＋改行と完全一致（展開されない） | `GifMarkerTests.testFileArgumentsAreLiteralAndHaveNoText`、変異 GIF-FILE-TEXT-FLAG、GIF-FILE-SHELL |
| B2 | 新規 | パスが `""`、`"x.gif"`、`"-x.gif"`、`"/tmp/a\u{0}b.gif"`、`"/tmp/a\nb.gif"` | `sendFileArguments` が nil | `GifMarkerTests.testFileArgumentsRejectUnsafePaths` |
| B3 | 回帰 | 既存の `sendArguments` と、Sources に `/bin/sh`・`osascript`・`NSAppleScript`・`"-c"` が無いこと | 今どおり。`SignalTests.testImsgCommandsUseLibexecArgumentsOnly` に `sendFileArguments(chatID: 3, path: "/a.gif") == ["send","--chat-id","3","--file","/a.gif","--json"]` を足す | `SignalTests.testImsgCommandsUseLibexecArgumentsOnly`、`GroupTransportTests.*`、変異 GC20-SHELL-COMMAND |

### 5.3 GIF の検査

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| C1 | 新規 | `MarkerImage.check` に nil / 存在しないパス / 空ファイル / ディレクトリ / 正しい GIF へのシンボリックリンク / 相対パス / 生文字列の NUL を含むパス / 読めないファイル（root なら skip）/ フィクスチャ GIF | 順に `missing` / `missing` / `empty` / `not_regular` / `not_regular` / `invalid_path` / `invalid_path` / `unreadable` / `usable(path: gif)`。NUL は URL 正規化前の文字列で確認する | `GifMarkerTests.testImageCheckClassifiesEachCase` |

### 5.4 1通目の送信

すべて `splitHarness` 相当（許可済み chat 7、route あり、返事1件）で `pollReplies()` を通す。

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| D1 | 新規 | 既定（GIF 使える）、script 空 | `outgoing` が `[(7,.file(gif)), (7,.text(B))]`。文字の `M` も設定の目印も送らない。`rateEvents`（chat 7）1件。`reply_sent` が detail `marker_image` と `body` で各1件。`handledReplyIDs` に r1 | `testImageSuccessSendsNoTextMarker`、変異 GIF-SUCCESS-ALSO-TEXT |
| D2 | 新規 | script `[.failure(.failed), .success(guid "txt-1"), .success(guid "body-1")]` | `outgoing` が `[.file(gif), .text(M), .text(B)]`。2通目を送る時点（`onSend` で観測）で `partial_replies[0].marker_guid == "txt-1"`。`sentGUIDs` に `txt-1` と `body-1`。`rateEvents` 1件。`marker_image_failed` が warning で1件。deadletter なし | `testImageFailedFallsBackToMarkerAndContinues` |
| D3 | 新規 | `reply_marker: "🕊️"`、画像 `.failed` | 文字は `"🕊️"`（`M` ではない）、その後 `B` | `testImageFailedFallsBackToConfiguredMarker`、変異 GIF-DEFAULT-MARKER |
| D4 | 新規 | 画像 `.failed` のあと文字が (a) `.failed` (b) `.uncertain` (c) `.notStarted` | (a) `[file, M]`、deadletter `send_failed`、`rateEvents` 0、処理済み、本文なし (b) `[file, M]`、deadletter `send_uncertain`、`rateEvents` 1、処理済み、再試行と再取得でも増えない (c) `[file, M]`、`heldLockCount` 1、`lastError == "apple_event_1712"`、`rateEvents` 0。15秒進めて `retryHolds()` すると `[file, M, file, B]`（再試行は画像から） | `testFallbackTextFailureFollowsMarkerRules` |
| D5 | 新規 | 画像が (a) `.uncertain` (b) `.success(guid "")` | どれも `outgoing == [.file(gif)]`。15秒後の `retryHolds()` と次の `pollReplies()` でも増えない。deadletter `send_uncertain`、`rateEvents` 1、`handledReplyIDs` に r1、`partial_replies` 空、`send_uncertain` のログ detail `marker_image`。タイムアウトが `.uncertain` になることは Engine から `SendLaunch` を直接呼ばず、既存の `SignalTests`（タイムアウト解釈）で確認する（無ければ1件足す） | `testImageUncertainSendsNothingMore`、変異 GIF-UNCERTAIN-FALLBACK。分類は `SignalTests` |
| D6 | 新規 | 画像 `.notStarted`、その後は既定成功 | 直後は `outgoing == [.file]`（文字なし）、`heldLockCount` 1、`lastError == "apple_event_1712"`、`rateEvents` 0、`partial_replies` 空、`apple_event_1712` のログ detail が `marker_image`。15秒進めて `retryHolds()` で `[.file, .file, .text(B)]`、`rateEvents` 1 | `testImageNotStartedHoldsAndRetriesImageFirst`、変異 GIF-NOTSTARTED-FALLBACK、GIF-RETRY-TEXT |
| D7 | 新規 | D6 の保留中に `h.markerImage` を nil に変える（エンジンは同じ Harness の locator を参照すること。`MutableMarkerImage` のような参照型でよい） | 再試行で `[.file, .text(M), .text(B)]` | `testRetryUsesTextWhenImageWentMissing` |
| D8 | 新規 | GIF が (a) nil (b) 空ファイル (c) ディレクトリ (d) 存在しないパス (e) 相対または NUL を含むパス (f) 正しい GIF へのシンボリックリンク (g) 読めないファイル（root なら skip） | `sentFiles` 0（画像の送信を起動しない）。`outgoing == [.text(M), .text(B)]`。`marker_image_unavailable` warning、detail は `missing` / `empty` / `not_regular` / `missing` / `invalid_path` / `not_regular` / `unreadable` | `testUnavailableImageFallsBackWithoutLaunching`、変異 GIF-ACCEPT-DIRECTORY |
| D9 | 新規 | GIF 無しで返事2件（別 reply_id、同じ chat、順に完了）→ GIF を戻して返事1件 → また無くして返事1件 | `marker_image_unavailable` は 1件 → 増えない（戻した回は画像で送る）→ もう1件（計2件）。ログにパスの文字列が含まれない | `testUnavailableImageLogsOnceUntilResolved` |
| D10 | 新規 | 画像 `.failed` を返す直前（`onSendFile`）に `setPaused(true)` | 文字は送らない（`outgoing == [.file]`）。1通目の保留（一時停止）、`rateEvents` 0。解除して `retryHolds()` すると `.file` から始まる | `testPauseAfterImageFailureHoldsWithoutText` |
| D11 | 新規 | 画像送信の最中（`onSendFile`）にデータベースの入れ替え（既存テストと同じ手順で guid を変える） | 画像の guid は `sentGUIDs` に入る、本文は送らない、`partial_replies` なし、処理済み、`reply_dropped_db_reset` detail `marker` | `testDatabaseResetDuringImageDropsTheBody` |
| D12 | 回帰 | レート上限（既定1分5件）で、別の返事を6件 | 画像の5件のあと6件目は送らず `rate_limited`。画像も文字も起動しない | 既存のレートのテストを画像既定に移す（変異は既存のレートのもの） |
| D13 | 新規 | 画像の `sendFile` が `SendFailure` 以外の Error を throw する（FakeSender.throwNext） | `.failed` と同じ。`outgoing` が `[.file(gif), .text(M), .text(B)]`。`marker_image_failed` が warning で1件。本文まで届く | `testImageThrowFallsBackLikeFailed` |

### 5.5 ループ防止・指紋

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| E1 | 新規 | D1 のあと（画像の guid `sent-1`）、許可したトークで guid `sent-1`、`is_from_me` true、本文 `"🪔 test"` の watch 行 | `.ignoredSentGUID`。webhook の呼び出し 0 | `testImageGuidIsIgnoredWhenWatchEchoesIt`、変異 GIF-NO-SENTGUID |
| E2 | 新規 | D1 の画像送信中（`onSendFile`）と完了後の state | 送信中は `pending_sends` に `part: marker`、`marker_kind: image`、`hash: ""`。完了後の `fingerprints` に `SHA256(M)` も `SHA256(config.replyMarker)` も無い（本文の分だけ）。そのあと120秒以内に、別の guid・他メンバー（グループで許可済み）の本文 `M` の行 → `.ignoredReplyMarker`（`.ignoredFingerprint` ではない） | `testImageMarkerAddsNoEmojiFingerprint`、変異 GIF-FINGERPRINT |
| E3 | 回帰 | GIF 無し（文字フォールバック）で設定の目印を送り、同じ文の echo | `.ignoredFingerprint`（今どおり） | `GroupPrivacyRegressionTests.testConfiguredMarkerAlsoAppliesToSelfChatAndFingerprint`（文字フォールバックに移す）、変異 GC16-FINGERPRINT |
| E4 | 新規 | 起動時の state に `pending_sends: [{part: marker, marker_kind: image, hash: ""}]`（画像送信中に落ちた） | `send_interrupted` の deadletter、r1 は処理済み、`fingerprints` は増えない、その後の `pollReplies()` で何も送らない | `testInterruptedImageMarkerAddsNoFingerprint` |
| E5 | 回帰 | `marker_kind` の無い古い `pending_sends`（文字の hash あり） | 今どおり指紋を足し、`send_interrupted` | 既存の起動時のテスト（SplitReplyTestsRetry） |
| E6 | 回帰 | 許可したトークで、記録の無い guid・本文 `""` と `"\u{FFFC}"` の行 | `.ignoredNoSignal`、webhook 0。`isReplyMarker` と 🪔 の判定は変えない | `testAttachmentOnlyEchoIsNotASignal`（合図の判定は変えないので新しい変異は足さない） |

### 5.6 2通目

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| F1 | 回帰 | `testSecondMessageHasNoMarkerOrLeadingSpace` の入力全部 | 各入力で `outgoing == [.file(gif), .text(B)]`、2通目の先頭に空白も 🧞 も無い | SplitReplyTests を画像既定に移す |
| F2 | 回帰 | グループで安全な呼び名がある route | `[.file(gif), .text("呼び名へ：本文")]`。画像に接頭辞の概念は無い | GroupReplyNameTests を画像既定に移す、変異 NAMEPREFIX1 |
| F3 | 回帰 | 本文が空（`M` だけ、空白だけ）、または本文が 🪔 で始まる | `outgoing` 空（`sentFiles` も 0）、処理済み、`reply_empty_body` / `reply_still_matches_signal` | SplitReplyTests を画像既定に移す |
| F4 | 回帰 | 画像成功、本文 `.failed`、送り直し成功 | `[.file, .text(B), .text(B)]`。画像は送り直さない。`rateEvents` 1 | SplitReplyTestsRetry を画像既定に移す |
| F5 | 回帰 | 画像成功、本文も送り直しも `.uncertain` | `[.file, .text(B), .text(B)]`、deadletter `body_send_uncertain`、それ以上送らない | 同上 |

### 5.7 部分送信の再開

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| G1 | 回帰（画像の道） | 画像成功のあと、2通目を送る前に止まった state（`partial_replies` に `marker_guid: "sent-1"`、`sent_guids` に `sent-1`）で、新しいエンジンを作って `pollReplies()` | `outgoing == [.text(B)]`、`sentFiles` 0（画像を送り直さない） | `testRestartAfterImageSendsOnlyTheBody` |
| G2 | 回帰（画像の道） | 保存の順（S1〜S4） | S1 は `pending_sends` に marker（`marker_kind: image`）、S2 は `partial_replies.marker_guid == "sent-1"` かつ `sent_guids` に `sent-1`、S3・S4 は今どおり | `SplitReplyTests.testSavesHappenInOrder` を画像既定に移す |
| G3 | 回帰 | 画像成功のあと `partial_replies` の保存に失敗 | 2通目を保留し、保存できるまで送らない。画像は送り直さない | 既存の保存失敗のテストを画像既定に移す |

### 5.8 文書と変異

| ID | 区分 | 条件 | 期待 | 確認方法 |
|---|---|---|---|---|
| H1 | 新規 | README | `返信の印: 1通目は同梱の GIF 画像だけ` を含み、`返信の印: 1通目は `reply_marker`（既定 🧞‍♂️）だけ` を含まない。`--file` と `--text` を付けないことが書いてある | `GroupDocumentationTests.testReadmeExplainsFamilyGroupsAndReplacesOldMarkerParagraph` の最後の期待を新しい文に直す、変異 GIF-DOC-OLD、GC24-RESTORE-OLD-MARKER-PARAGRAPH（文脈を直したもの） |
| H2 | 新規 | SPEC | `24. 1通目の GIF` を含む。決定 20 と 22 の本文は v1.2.0 と同じ文字列のまま。9章に「`imsg send --file` が画像だけの1通として届くか」「guid が返るか」「watch に戻ったときの本文と添付の形」「家族の端末でアニメーションが見えるか」が、それぞれ「未確認」を含む行である | `GroupDocumentationTests.testSpecRecordsGifMarkerDecisionAndHardwareChecks` |
| H3 | 回帰 | `testMarkerDocumentsFirstGraphemeEmojiConstraint` ほか既存の文書テスト | 通る | 既存、変異 GF1-DOC-MARKER |
| H4 | 新規 | `tools/mutants/*.patch` 全部 | `git apply --check` が通る。manifest に 4.12 の Linux 12個がある（macOS の assemble 変異は manifest に無い）。`python3 tools/check-mutants.py` で manifest の全部が `KILLED`。macOS 変異は `tools/run-mutants.sh macos` | CI の linux ジョブ、`tools/run-mutants.sh macos` |
| H5 | 回帰 | 追跡ファイルの個人情報検査 | 通る（GIF は対象外、文書に実在の番号・メール・トークンを足さない） | `scripts/check-tracked-text.py`、`NotionReplyTests.testPersonalIdentifiersStayOutOfDocsAndTests` |

### 5.9 完了の確かめ方

```bash
swift build
swift test
for p in tools/mutants/*.patch; do git apply --check "$p" || echo "FAIL $p"; done
python3 tools/check-mutants.py
python3 scripts/check-tracked-text.py
sha256sum AppBundle/ReplyMarker/reply-marker.gif   # fc645a3d…efcd3c
```

macOS の CI で `LampIconTests.testAssembleCopiesReplyMarkerGif` と `tools/run-mutants.sh macos` が通ること。

## 6. 実機未確認（この作業では確かめない）

この実装の範囲で実送信はしない。次はすべて実機未確認で、Mac mini でオーナーの自分宛てトークから、オーナーの OK のあとに確かめる。

1. imsg 0.19.1 の `send --chat-id <id> --file <path> --json`（`--text` なし）が受け付けられ、Messages で画像だけの1通として届くか。`--text` が必須で拒まれるなら、終了コードが 0 以外で `status` が無い → `.failed` → 文字フォールバックになる（安全）。
2. 画像送信で `{"status":"sent","guid":…}` の guid が返るか。imsg は本文の一致で guid を探すと考えられ（SPEC 9章）、画像だけでは見つからない恐れがある。guid が無ければ結果不明として扱うので、**GIF だけが届いて2通目は毎回送られない**。この場合も文字は足さない（GIF と絵文字の二重を避けるため）。実機でこうなったら、v1.2.0 に戻すか、切り替えの設定を足すかをオーナーが決める（7章）。
3. watch に戻ってきた自分の画像の行の形（本文が空か U+FFFC か、添付の欄、guid が送信の結果と同じか、`is_from_me`）。guid が一致すれば `ignoredSentGUID`、しなくても合図にはならない。
4. 家族の端末（iPhone、Mac）でアニメーションが動いて見えるか。グループでも画像が届き、GIF と本文が順に並ぶか。
5. パスに空白がある場所（例: 名前に空白のあるフォルダに置いた .app）で、imsg 内部の AppleScript がパスを正しく扱うか。通常は `/Applications/Genie.app/…` で空白は無い。
6. 画像送信の所要時間と、-1712 のときに `not_started` が出るか（文字と同じか）。

## 7. 残した判断（オーナーに確認したいこと）

- 画像の guid が実機で返らなかったときの戻し方。今回は切り替えの設定を足さない（依頼の範囲外）。必要なら `reply_marker_image`（真偽）のような設定を別の作業で足す。
- 送信時に GIF の中身（マジック、ハッシュ）まで確かめるか。今回は存在・通常ファイル・サイズ・読めることだけ。中身はテストと assemble で固定する。
- GIF が使えずに文字で送っているとき、メニューに出すか。今回はログ（`marker_image_unavailable`）だけ。
- シンボリックリンクの GIF は使えないものとした（.app の中は通常ファイルのため）。
