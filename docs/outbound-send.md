# 外部からの送信依頼（伝書鳩の通知を Genie から送る）

対象は `genie-in-messages` の `feat/outbound-send` です。PR #26 は取り込み済みです。仕様日付は 2026-11-16 です。

本書は実装後の仕様です。このブランチ（PR #26 取り込み後）の Linux の全体 `swift test` は、2026-11-17 の確認で566件・失敗0件でした（モックによる確認）。Mac mini での配送確認は別で、12章に記録します。Core のテストが通っても、実機で届いたことの証明にはなりません。

## 1. 目的とオーナーの決定

伝書鳩（別の Grok Bot）は、予定のまとめと1時間前のリマインドを作っています。これを Linq ではなく、Mac mini の Genie の iMessage から家族グループへ送ります。Linq からは、2026-11-14 から家族グループへの送信が 403 になっています。

オーナーが承認した設計は次の3つです。

1. 送信依頼には、**専用の Notion データベース（データソース）**を使う。返事用のデータソースとは分ける。
2. 行に書ける送り先は **`family` と `self` だけ**にする。
3. **実際の送り先（トークの GUID）は、Mac mini の `config.json` にだけ置く。**行の中身から送り先を決めない。

オーナーの要件「同じ本文を二重に送らない」は、既存の返事の規則（結果が分からなければ本文を1回送り直す）より優先します。そのため、**外部依頼の本文は一度も送り直しません**（8.4）。既存の返事の規則は変えません。

## 2. 経路を選んだ理由

| 比較 | 専用 Notion データソース（採用） | Job Engine の `delivery_outbox` |
|---|---|---|
| 取得 | トーク読み取り、ページング、再試行、水位 cursor は既にある | `GET /genie/replies` は返事用。ジョブの無い通知の送り先を表せない |
| 送り先 | 新しい解決処理を Genie の中に足す | `deliverReply` は元メッセージへの route が無い行を送らない。公開の enqueue はジョブを前提に送り先を決める |
| 伝書鳩からの接続 | Notion コネクターで行を足すだけ。Mac へ直接つながなくてよい | box から Mac の Job Engine へ届く通信路が要る |
| 変更する範囲 | Genie の中だけ | Job Engine の API と Genie の両方 |

下調べには「`job_id` は NOT NULL なので移行が要る」とありましたが、これは誤りです。Job Engine の v2 の移行で、`delivery_outbox.job_id` は null にできるようになっています。ただ、それでも上の理由から今回は採用しません。

## 3. 範囲

### 3.1 含めるもの

- 送信依頼専用の Notion データソースの取得（`OutboundSource`、`FetchedOutbound`、`NotionOutboundSource`）
- `family` と `self` だけを表す型（`OutboundTarget`）と、設定とトーク一覧を使った送り先の解決
- 永続の冪等記録（ledger）、同じ本文の抑止、段階ごとの再開
- 既存の2通送信（GIF または文字の目印と、本文）の共通化
- Core のテスト、変異パッチ、SPEC・README・`config.example.json` の更新

### 3.2 含めないもの

- 伝書鳩のコード、ルーチン、設定の変更（11章の手順として書くだけ）
- Job Engine の変更、家族 Job 経路の有効化
- Mac mini での操作、導入、実送信、権限の付与
- メニュー UI の変更と、snapshot に件数を足すこと（後回し）
- 配送結果を Notion や伝書鳩へ書き戻すこと
- 複数の Mac による同時送信

### 3.3 既存の経路との分離

- 既存の返事は、これまでどおり `in_reply_to_guid` と保存済みの route から送り先を決めます。外部依頼のために route を作り出したり、返事で route を省けるようにしたりはしません。
- 返事と外部依頼は別の型にします。`FetchedOutbound` を `FetchedReply` に変換して、返事用の検証を迂回することはしません。行の `target` は列挙型 `OutboundTarget { family, self }` に変換し、任意の宛先文字列を送信層へ渡しません。
- 外部依頼の途中経過は、state の `outbound` 領域にだけ持たせます。既存の `pending_sends` と `partial_replies` には入れません。入れると、再起動時に返事の再開規則（結果不明の本文を1回送り直す）が当たってしまうためです。

### 3.4 PR #26 で解消した失敗

レビュー時に main `71be743` で落ちていた次の2件は、PR #26 で修正して取り込み済みです。

- `GroupDocumentationTests.testSpecRecordsGifMarkerDecisionAndHardwareChecks`
- `ReviewFixesTests.testFailedSendIsDeadLetteredAndNotRetried`

PR #26 取り込み後の Linux の全体 `swift test` は、2026-11-17 の確認で失敗0件でした。これらを既知の失敗として除外しません。

## 4. 設定

### 4.1 新しいキー（3つ）

| キー | 型・既定値 | 規則 |
|---|---|---|
| `outbound_notion_data_source_id` | 文字列、`""` | 前後の空白を除く。空なら外部依頼の取得も新しい送信も行わない。空でないなら `NotionDataSourceID.canonical` で検証する |
| `outbound_targets` | オブジェクト、`{}` | 使えるキーは `family` と `self` だけ。値はトークの GUID 文字列で、前後の空白を除く。空文字はそのキーを設定していないのと同じ |
| `outbound_max_age_seconds` | 整数、`900` | 60〜3600。依頼が作られてからこの秒数を過ぎたら送らない |

- キーが無いときと null のときは既定値にします。古い config もそのまま読めます。旧版の Genie は新しいキーを無視するので、この機能は動きません。
- 次の場合は `config_unreadable` にして、直前の有効な設定を使い続けます。
  - 型違い
  - `outbound_targets` に未知のキーがある、または値が文字列でない
  - `outbound_max_age_seconds` が整数でない、または範囲外（59、3601 など）
  - 値を黙って補正はしません。
- 同じ宛先・同じ本文を抑止する時間は**600秒の固定値**で、設定にはしません（`OutboundLimits.duplicateBodySeconds = 600`）。

### 4.2 設定の矛盾

| 条件 | 扱い | コード |
|---|---|---|
| `outbound_notion_data_source_id` が canonical にならない | 外部依頼だけを無効にする。返事はそのまま動く | `outbound_source_invalid` |
| 返事用の `notion_data_source_id` と canonical ID が同じ | 外部依頼だけを無効にする | `outbound_source_conflict` |
| `family` と `self` の GUID が同じ（**大文字小文字を無視して比べる**） | 両方を設定していないものとして扱う | `outbound_target_collision` |

`family` と `self` の衝突は大文字小文字を無視して比べ、厳しい側に倒します。一方、送り先の解決（6章）は大文字小文字を区別した完全一致です。

### 4.3 許可との関係

`outbound_targets` は送り先を選ぶだけで、許可は与えません。

- family には、`group_chat_guids` による設定の許可が要ります。
- self には、メニューでの許可が要ります。
- メニューで許可したトークでも、`outbound_targets` に書いていなければ外部依頼の送り先にはなりません。

### 4.4 架空の設定例

```json
{
  "outbound_notion_data_source_id": "11111111-1111-4111-8111-111111111111",
  "outbound_targets": {
    "family": "iMessage;+;chat000000000000000001",
    "self": "iMessage;-;owner@example.com"
  },
  "outbound_max_age_seconds": 900,
  "group_chat_guids": ["iMessage;+;chat000000000000000001"],
  "self_chat_ids": [7]
}
```

## 5. Notion の行

### 5.1 列

| 列 | Notion の型 | 条件 |
|---|---|---|
| `idempotency_key` | title | ASCII の英数字と `-._:` だけで、1〜128文字。通知が1回起きるごとに伝書鳩が決めて、その後は変えない |
| `target` | rich_text | `family` か `self` に完全一致すること。前後の空白や大文字小文字の違いも一致しないものとする |
| `text` | rich_text | 送る本文 |
| `created_at` | created_time | Notion が付ける作成時刻 |

- 冪等キーは `idempotency_key` の1つだけです。別の `request_id` 列は作りません。Genie は Notion のページ ID を**別名**として記録し、同じページを編集しても別の送信にならないようにします（9.3）。
- キーには、電話番号、メール、ハンドル、予定の題名を入れません。例: `pigeon:demo:20261116T090000Z:reminder`
- `chat_id`、`guid`、`in_reply_to_guid`、ハンドルなどの列があっても、送り先の解決には一切使いません。読み取りもしません。
- Notion の title に一意制約があるとは考えません。一意かどうかは、書き手の約束と Genie の ledger で守ります。
- 期限と水位には、ページオブジェクトの `created_time` を使います。

### 5.2 行のデコード

- title と rich_text は、全部の要素について `type` と文字列の `plain_text` を確かめてから、順に連結します。**要素が1つでも壊れていたら、その列は読めない**ものとします。読める要素だけをつなぐことはしません。
- select、number、formula、relation を文字列に変換しません。

| 応答の状態 | 扱い |
|---|---|
| ページ ID かページの `created_time` が読めない | **取得の失敗**。cursor を進めない。原文はログに出さない |
| ページ ID と `created_time` は読めるが、列が無い・型が違う・一部の要素が壊れている・キーの形が規則に合わない | ページ ID のハッシュで記録して終端（`outbound_bad_entry`） |
| `created_time` が今より60秒を超えて未来 | 終端（`outbound_bad_entry`） |
| `target` が `family` でも `self` でもない | 終端（`outbound_unknown_target`） |

終端にした行は、あとで編集されても復活させません。行は全部の列を揃えて一度に作るのが約束です。

### 5.3 本文の検証

次の順で確かめます。

1. `text` を NFC に正規化する。
2. 正規化した元の本文で `Signal.matches` が真なら拒否する（`outbound_signal_body`）。先頭の空白・不可視文字・VS16 を伴う 🪔 も対象。
3. 元の本文が8000 Unicode スカラーを超えるか、U+0000 を含めば拒否する（`outbound_text_invalid`）。
4. `ReplyComposer.split(body:marker:)` で、先頭の目印と空白を外す。
5. `.emptyBody` なら拒否する（`outbound_empty_body`）。`.stillSignal` なら拒否する（`outbound_signal_body`）。
6. 整形後の本文が8000スカラーを超えれば拒否する（`outbound_text_invalid`）。バイト数の上限は別に設けない。

- 切り詰めたり、複数の本文に分けたりはしません。
- 既存の返事では `"🪔 answer"` が `"answer"` になりますが、外部依頼は手順2で拒否します。`ReplyComposer` の既存の動きは変えません。
- 本文にグループの呼び名（`{addressee}へ：`）は付けません。外部依頼には元の発言者がいないためです。

## 6. 取得と cursor

### 6.1 取得元

- Notion の通信、トークン、時刻の扱い、ページングは既存の処理と共有します。行のデコーダーは返事用とは別にします。
- `Notion-Version: 2026-03-11` を使います。`created_time` の昇順で query し、1ページ100行、1回の取得で最大20ページまで読みます。
- 新しい依頼を1回で扱う件数の枠は `reply_page_limit` です。処理済み、保留中、送信中、同じトークで前の送信を待っている依頼は、この枠に数えません。
- 429、529、500、503 は既存と同じ待ち方で、最大5回試します。5回目も待ってから、その取得を打ち切ります。
- トークンは同じ `notion-token`（0600）を使い、取得のたびに読み直します。Genie 側の権限は読むだけです。

### 6.2 共有の間隔管理

返事と外部依頼の取得は、**1つの共有の間隔管理**（actor にした `NotionPace`）を通します。合わせて毎秒3回まで、つまりリクエストの間を1/3秒以上空けます。

- 間隔管理はランタイムが1つだけ持ち、`ConfiguredReplySource.prepared` と外部依頼の `prepared` に渡します。取得元を作り直しても、最後のリクエスト時刻は失いません。
- main の `NotionPace` はロックの無いクラスで、取得元ごとに持っています。これは今回の変更の対象です。`@unchecked Sendable` を同期の代わりにはしません。

### 6.3 独立した cursor

state に `outbound_notion_cursor` を足します。中身は、ソース ID の canonical 形の SHA-256、水位、seen、開始の下限です。既存の `reply_cursor` と `http_reply_cursor` は変えません。

- cursor が空なら、取得を始めた時点の「今の分の先頭」を開始の下限にします。**この下限は通信を始める前に保存します。**保存できなければ、取得も送信も始めません。
- 読み直しは水位の120秒前からです。ただし開始の下限より前には戻りません。
- 未完了の依頼の `created_time` より先に、水位を進めません。このため、再起動後に本文を取り直す元のページ（9.4）は、取得の範囲に残ります。
- 行の予約や終端の記録を保存できなければ、その行を越えて cursor を進めません。cursor の seen は最適化のためのもので、重複防止の正本は ledger（9章）です。
- データソース ID を変えた（空にした場合も含む）ときは、旧ソースの未完了の依頼を `outbound_source_changed` で終端にし、新しい cursor を空から始めます。ledger は消しません。
- 20ページを超えて依頼がたまると、後ろの行を読めないことがあります。時間内の配送は保証しません。期限切れの処理と二重送信の回避を優先します。

### 6.4 本番の入口

定期処理を起こすのは、これまでどおり `GeniePoller.tick()` だけです。1周の順序は次のとおりです。

1. 画面ロックの状態を更新する
2. 必要ならトーク一覧を取得して反映する
3. 保留の再試行（`retryHolds()`。返事と外部依頼の両方）
4. 既存の返事の取得（両方あれば HTTP、Notion の順）
5. 外部依頼の取得（`pollOutbound()`）

- 返事の取得元が設定されていないときや、手順4が失敗したときも、手順5は実行します。
- 外部依頼の取得間隔は返事と同じ設定値を使いますが、取得が終わった時刻から独立に数えます。一時停止を解いたときと、一覧を確かめられるようになったときは、次の tick で取りに行きます。
- 次のときは、新しい取得も送信も始めません。
  - 最初の一覧照合の前
  - 一時停止中
  - 停止後
- ledger が上限に達したとき（9.6）に止めるのは、**新しい予約だけ**です。取得は続け、既存の未完了の再開（再起動後の本文の取り直しを含む）はできます。
- await から戻るたびに、停止、DB の世代、ソースの世代を確かめます。設定と取得元は取得を始めたときに固定し、戻ってきた結果を新しい設定のソースのものとして扱いません。

## 7. 送り先の解決

### 7.1 解決の手順

`resolveOutbound(target, config, directory) -> .resolved(chatID, guid, selfBasis?) | .hold(code) | .reject(code)` は、上から順に判定します。

| # | 条件 | 結果 | コード |
|---|---|---|---|
| 1 | 機能が無効、またはその target の GUID が空・未設定 | 終端 | `outbound_target_unset` |
| 2 | family と self の衝突（4.2） | 終端 | `outbound_target_collision` |
| 3 | 最初の一覧照合の前、直近の一覧取得の失敗、一覧が空 | 保留 | `outbound_held_unverified` |
| 4 | 最後に成功した一覧で、`chat.guid == 設定の GUID`（**大文字小文字もサービス部分も区別するバイト単位の完全一致**）のトークを数え、0件だった | 保留 | `outbound_held_unverified` |
| 5 | 4で2件以上 | 保留（どれも選ばない） | `outbound_target_ambiguous` |
| 6 | family の資格（7.2）が無い | 終端 | `outbound_family_not_configured` / `outbound_family_not_group` |
| 7 | self の資格（7.3）が無い | 終端。ただし判定できないときは保留 | `outbound_self_not_self` / `outbound_held_unverified` |
| 8 | 実効の許可（メニューと設定の和）がオフ | 終端 | `outbound_chat_disabled` |
| 9 | すべての許可元の GUID が一致しない（SPEC 4.3・4.11 と同じ照合。DB の入れ替えリセットが起きないまま GUID だけ違う場合を含む） | 終端 | `outbound_guid_mismatch` |

- `iMessage;+;…` と `imessage;+;…`、`iMessage;+;…` と `any;+;…` や `SMS;+;…` は、別の GUID として扱います。補正しません。
- 表示名、参加者名、`identifier`、行の余分な列から、送り先を補いません。
- **`ConfigGroupAuthorization` の「GUID に最初に一致したトークを選ぶ」処理は、解決に使いません。**chat_id は手順4・5の候補からだけ決めます。`ConfigGroupAuthorization` は、決まった chat_id の許可を確かめる手順8・9でだけ使います。
- 保留した依頼は期限（8.6）まで待ち、期限を過ぎたら `outbound_expired` で終端にします。一覧の取得に失敗したときは最後に成功した一覧の情報を残しますが、それを理由に送信を許すことはしません。

### 7.2 family

次の両方を満たすときだけ、資格があるとします。

1. GUID が**現在の** `group_chat_guids` に入っている（完全一致）。
2. 一覧の該当する行を `SelfChat.resolveGroup` でグループと判定できる。

メニューだけで許可したグループには送りません。`group_chat_guids` から外したら、メニューの許可が残っていても、外部依頼は終端になります。通常の返事の「許可の和」の規則は変えません。

### 7.3 self

グループでないことが必須です。そのうえで、次のどちらかを満たすことを**根拠**とします。

- `participant`: 空白でない participant がちょうど1人で、その人が SPEC 4.10 と同じ正規化で、自分のハンドル候補と一致する。
- `self_chat_ids`: 解決した chat_id が、現在の `self_chat_ids` に入っている。

その他の規則は次のとおりです。

- グループは、`self_chat_ids` に入っていても拒否します。受信の echo 判定の上書き規則より厳しくしています。
- 普通の1対1（participant が自分のハンドル候補と一致しない）は終端です。
- participants が無い・空・読めない、または自分のハンドル候補がまだ無い場合は判定できません。このときは保留にし、期限で終端にします。`SelfChat.ignoresInboundEcho == true` を自分宛ての証拠に使いません（判定できないときも真になるため）。

### 7.4 解決を確かめ直すタイミング

予約したときに `target` と宛先 GUID のハッシュを固定します。1通目の直前（GIF から文字へ切り替える直前も含む）と本文の直前には、そのつど 7.1 をやり直し、次をすべて満たすときだけ送ります。

- 解決できる（`.resolved`）
- 現在の設定 GUID のハッシュが、予約したときの値と同じ
- chat_id が1通目のときと同じ
- self の場合は、**根拠が1通目のときと同じ**であること
  - 1通目の直前に、根拠の種類（`participant` / `self_chat_ids`）を ledger に保存する。participant の正規化値はメモリにだけ持つ。
  - 同じプロセスの中では、種類と participant の正規化値の両方が同じであることを要求する。
  - 再起動したあとはメモリの値が無いので、種類が同じで、今の情報でもう一度その根拠が成り立つことを要求する。
  - 根拠の種類や値が変わった、自分のハンドル候補が変わって一致しなくなった、`self_chat_ids` から外れた、のどれでも送らない。

食い違ったときは、その依頼を `outbound_target_changed` で終端にし、新しい宛先へ付け替えません。機能を無効にした場合と、family を `group_chat_guids` から外した場合も同じです（それぞれ `outbound_source_changed` と `outbound_family_not_configured`）。

## 8. 送信

### 8.1 共通の処理

既存の `sendMarker` と `sendBody`（GIF、文字への切り替え、レート、ロック、指紋、送信済み GUID の記録）を共通化し、送信元の型（返事 / 外部依頼）と、それぞれの方針を引数で渡します。外部依頼専用に GIF 送信を別に作ることはしません。

方針として分けるのは次の4つです。

1. 送り先の確かめ直し（返事は route、外部依頼は 7.4）
2. 本文を送り直すかの判断（返事は `BodyResendPolicy` のまま、外部依頼は送り直さない。8.4）
3. 途中経過の保存先（返事は `pending_sends`・`partial_replies`、外部依頼は `outbound` の stage）
4. ログのコード（外部依頼は 10章）

### 8.2 1通目

SPEC 4.4 と `docs/gif-marker.md` の契約をそのまま使います。

| 結果 | 動作 |
|---|---|
| GIF が使える | `sendFile` で画像だけの1通目を送る |
| GIF が無い・空・通常ファイルでない・読めない・パスが使えない形 | 画像は起動せず、`reply_marker` の文字を送る |
| GIF が `.failed` | 同じ試みの中で `reply_marker` の文字に切り替える |
| GIF が `.uncertain`、または成功応答の GUID が空 | 文字も本文も足さずに終端（`outbound_send_uncertain`） |
| GIF・文字が `.notStarted` | 保留してレートを戻す。次の試みで GIF の場所を確かめ直し、使えれば画像から試す |
| 文字が `.failed` / `.uncertain` | 本文を送らずに終端（`outbound_send_failed` / `outbound_send_uncertain`） |
| 空でない GUID を得た | `sentGUIDs` に入れ、stage を `body_ready` にして保存してから本文へ進む |

`.notStarted` は、起動の失敗と、-1712 に `not_started` が付いたものです。-1712 だけのものとタイムアウトは `.uncertain` です。

`SendResultParser` は読めない応答も `.failed` にするので（8.4）、GIF の `.failed` は「GIF が届いていない」ことを確定しません。それでも、GIF の `.failed` で文字に切り替えるのは、オーナーが承認した既存の GIF 契約のままにします。この場合、GIF と文字の目印の両方が届くことがあります（12章の4で確かめる）。本文はこの切り替えに関係なく、最大1回です。

### 8.3 本文

本文は 5.3 で整形した値を使い、`--text` の1つの要素として渡します。

### 8.4 本文は送り直さない（外部依頼だけの規則）

既存の `SendResultParser` は、成功の GUID も既知の状態も読めない応答（空の出力、壊れた JSON、`"nope"` のような未知の応答）を `.failed` にします。そのため、`.failed` は「届いていない」ことを確定しません。**外部依頼の本文は、どの結果でも一度も送り直しません。**

| 本文の結果 | 動作 | コード |
|---|---|---|
| 空でない GUID | 完了 | `outbound_body_sent` |
| `.notStarted` | stage を `body_ready` に戻して保存し、保留する。本文の send の回数に数えない | `outbound_held_not_started` |
| `.failed`（読めない応答・空の出力・未知の応答を含む） | **送り直さず**、deadletter にして終端 | `outbound_body_send_failed` |
| `.uncertain`（タイムアウト、-1712 だけを含む）、または成功応答の GUID が空 | **送り直さず**、deadletter にして終端 | `outbound_body_send_uncertain` |
| 送信の途中で止まった（再起動したとき、保存済みの stage が `body_in_flight`） | **送り直さず**、deadletter にして終端 | `outbound_body_send_interrupted` |

- 返事で使う stage の `body_retry_ready`・`body_retry_in_flight` と、回数の `body_resends` は、外部依頼では使いません。
- これで保証するのは、「本文の send は依頼1件につき最大1回（`.notStarted` で起動しなかったものは数えない）」ことです。相手の端末に届いたかどうかは Genie には分からないので、届いたことも、厳密に1回届くことも保証しません。送れなかった本文は deadletter とログに残り、オーナーが Messages で確かめます（11章）。
- 既存の返事（SPEC 4.4、決定20）の「失敗か結果不明なら本文を1回送り直す」「途中で止まったら1回送り直す」は変えません。

### 8.5 保留・ロック・レート・順序

- 1通目、文字への切り替え、本文の直前と、そのあいだの各 await のあとに、7.4 の確かめ直し、期限、一時停止、停止、画面ロックを確かめます。
- 画面ロック中は保留にします。ロックの状態が分からないときは、既存どおり送ってみます。一時停止中と停止後は送信を始めません。保留の再試行は `hold_retry_interval_seconds` を使います。
- レートは返事と合わせて数えます。依頼1件を1枠とし、1通目の前に予約します。
  - GIF から文字へ切り替えても数え直しません。
  - 本文は、枠も `halted_chat_ids` も見ず、枠も使いません。一時停止と停止は必ず見ます。
  - 1通目が `.failed` で終わったとき（文字への切り替えも失敗）と `.notStarted` のときは、枠を戻します。結果不明のときと1通目が届いたあとは戻しません。
  - レートの枠を戻すことと、冪等の記録を消すことは別です。終端にした依頼の記録は消しません。
- 同じトークでは、返事と外部依頼が送信順を共有します。前の2通が終わるか終端になるまで、次の1通目を送りません。

### 8.6 期限

期限は `created_time + outbound_max_age_seconds` です。秒数は予約したときの値を使います。

- 今の時刻が期限以上なら、新しい send を始めません。本文だけが残っている場合も、`.notStarted` の保留から本文を送る直前も同じで、`outbound_expired` で終端にします。
- 始めてしまった send は取り消せないので、期限のあとに結果が戻ることがあります。その結果を受けて次の送信は始めません。

### 8.7 ループ防止

次は既存と同じものを外部依頼にも当てます。

- 画像の GUID、文字の目印の GUID、本文の GUID を `sentGUIDs` に入れる。
- 文字の目印と本文には、既存の指紋（NFC のハッシュと時刻、120秒）を付ける。画像には付けない。
- 受信側では、目印を無視する判定と、自分宛てトークの `is_from_me=false` 側を無視する判定をそのまま使う。

本文は 🪔 で始まらないように検証しているので、webhook が起動しないことだけを見ても防御が働いているかは分かりません。そのため OB19 では、`ingestWatchLine` が返す**具体的な ignored の種類**も確かめます。自分宛ての echo の防御は、🪔 で始まり GUID も指紋も一致しない入力で、`ignoredNotFromMe` を直接確かめます（`ignoredNoSignal` や `ignoredSentGUID` で先に止まらないようにするため）。

### 8.8 プロセスの起動

`Process.executableURL` と引数配列だけを使います。

- 本文は `--text` の1つの要素にする。
- 画像は `--file` とパスを別々の要素にする。
- シェル、`eval`、つなげたコマンド文字列は使わない。

Linux で確かめられるのは、`ImsgCommand` の引数配列と Core の `ProcessRunner` までです。本番の `ImsgMessageSender`（`Sources/GenieMenuBar`、macOS 側）の配線は、実機での確認（12章）に回します。

## 9. 冪等と再起動

### 9.1 保証すること

- 同じ `idempotency_key` からは、送信処理を1回しか作らない（永久に）。
- 同じページ ID は、再取得しても、編集しても、新しい送信処理にならない（永久に）。
- 同じ送り先・同じ NFC の最終本文は、未完了のあいだと、`now < 最初の処理の終端の時刻 + 600秒` のあいだは、別のキーでも新しい送信処理にならない。ちょうど600秒からは送れる。
- 取得が重なっても、保留の再試行・レート停止の解除・再起動があっても、1通目を重ねて送らない（GIF の `.failed` から文字へ切り替える既存の契約は除く。8.2）。
- 本文の send は、依頼1件につき最大1回（`.notStarted` で起動しなかったものは数えない）。

ここでの「送信処理1回」は、1通目（GIF か文字）と本文1通のことです。

保証の範囲は、「同じキー・同じページは永久に1回」と「別のキーの同じ本文は600秒の抑止」です。「同じ本文を期限なしで二度と送らない」ことは保証しません。600秒を過ぎた新しいキーの同じ本文（翌日の同じリマインドなど）は、別の通知として意図して送ります。

### 9.2 state に持つもの

`PersistedState` に省略できる `outbound` 領域を足します。古い state では空として読みます。返事の `handled_reply_ids` とは分けます。

| 記録 | 内容 | 保持期間 |
|---|---|---|
| cursor | `outbound_notion_cursor`（6.3） | ソースを変えるまで |
| 依頼の記録 | キーのハッシュ、入力の署名（target と本文ハッシュ）、`target`、宛先 GUID のハッシュ、本文ハッシュ、`created_time`、期限の秒数、stage、self の根拠の種類、終端コード、終端の時刻、`deadletter_pending`（真偽）、ソース ID のハッシュ、未完了のあいだの chat_id | 自動では消さない |
| 別名 | ページ ID のハッシュ → 依頼の記録 | 自動では消さない |
| 本文の抑止 | 宛先 GUID のハッシュと本文ハッシュ → 未完了かどうか、終端の時刻 | 未完了のあいだと、終端の時刻 + 600秒まで。それ以後は消してよい |

- 本文、ハンドル、participant の値、ページ ID とキーの生の値、宛先 GUID の生の値は保存しません。本文は保存せず、再起動のあとは Notion の行から取り直して、保存済みの署名と照合します（9.4）。
- ハッシュは SHA-256 で、入力は「項目の種類のタグ＋長さ＋値」を並べたものにします。文字列を単純につないで衝突させないためです。
- 5000件で古いものから追い出す仕組み（処理済み ID、seen）は、ledger には当てません。

stage は次の値を取ります。

`reserved` → `marker_in_flight` → `body_ready` → `body_in_flight` → `terminal`

送り直しの stage（`body_retry_ready`・`body_retry_in_flight`）と回数（`body_resends`）は、外部依頼では持ちません。

### 9.3 予約と衝突

有効な行を受け取ったら、**最初の await より前に**メモリ上で予約し、**最初の send より前に**次を1回の state 保存で確定します。

- キー、ページ ID の別名、署名、宛先 GUID のハッシュ、期限、本文の抑止、stage `reserved`

保存できなければ send は0回です。cursor もその行を越えて進めません。

| 取得した行 | 動作 | コード |
|---|---|---|
| 記録済みのページ ID（再取得、編集後を含む） | 新しい処理を作らない。重複かどうかの判断には、編集した中身を使わない。ただし、その記録が未完了なら、復元のために中身を読む（9.4） | ― |
| 新しいページで、キーも内容（target・本文）も記録と同じ | 別名として保存し、そのページを終端にする。既存の処理は増やさない | `outbound_duplicate_key` |
| 新しいページで、キーは同じだが本文か target が違う | 別名として保存し、そのページを終端にする。元の記録は書き換えない | `outbound_idempotency_conflict` |
| 新しいページで新しいキーだが、同じ送り先・同じ最終本文が未完了か、`now < 終端の時刻 + 600秒` | そのキーとページを終端の記録として保存する | `outbound_duplicate_body` |
| 同じ本文でも送り先が違う | それぞれ許可を通れば送る | ― |
| `now >= 終端の時刻 + 600秒` の、新しいキーの同じ本文（翌日の同じリマインドを含む） | 送る | ― |

- 抑止の時間は、最初の処理が終端になった時刻から数えます。未完了のあいだは、時間に関係なく抑止します。重複した行を読んでも、時間は延ばしません。
- 不正な行（5.2）とその他の拒否も、ページ ID の別名と終端コードを保存します。直したあとで復活させないためです。

### 9.4 判断は保存済みの state で行う

- 各 send を始めてよいのは、その送信の `*_in_flight` を含む state の**保存が成功した**ときだけです。
- send の結果を受け取ったら、次の stage を保存します。保存できなければ、メモリ上ではその依頼をそれ以上進めません。送信もしません。次の tick で保存をやり直し、保存できるまで新しい予約も止めます（`outbound_state_save_failed`）。
- 起動したときは、メモリではなく**最後に保存できた JSON の stage** だけを見て、次の表で再開します。

| 保存済みの stage | 再起動後 |
|---|---|
| `reserved` | 元のページを取り直し、署名を照合し、解決と期限を確かめて続ける |
| `marker_in_flight` | `outbound_send_interrupted` で終端。1通目も本文も送らない |
| `body_ready` | 元のページから本文を取り直し、署名を照合して、本文だけを送る。1通目は送らない |
| `body_in_flight` | `outbound_body_send_interrupted` で終端。**送り直さない** |
| `terminal` | 何度取得しても送らない |

これで次の2つの順序でも、本文を送り直しません。保存済みの stage は `body_in_flight` のままなので、表のとおり終端になります。

1. 本文の send が成功 → 終端の保存が失敗 → 再起動
2. 本文の send の結果を受け取る前に停止 → 再起動

**本文の取り直し**（`reserved` と `body_ready`）は次のとおりです。同じプロセスの中では、予約したときのメモリの本文を使います。

- 取得で読んだ行のうち、ページ ID のハッシュが記録の別名と一致する行を元のページとします。水位は未完了の手前で止まるので（6.3）、元のページは取得の範囲に残ります。
- 取り直した `target` と、5.3 で整形した NFC の最終本文から署名を計算し、保存済みの署名と照合します。
  - 違えば（再起動の前にページが編集されていた場合）、送らずに `outbound_idempotency_conflict` で終端にします。列が壊れた、5.3 で拒否されるなど、署名を計算できないときも同じです。
  - 一致したときだけ、その本文で続けます。
- 元のページが取れない（取得の失敗、ページの削除、共有の解除などで、一致する行が無い）ときは、送らずに保留し（`outbound_held_body_unavailable`）、期限で `outbound_expired` の終端にします。

ほかの規則は次のとおりです。

- 起動時の整理（`*_in_flight` を終端にすること）を保存できなければ、外部依頼の送信を始めません。何度再起動しても、`*_in_flight` から送ることはありません。
- deadletter を伴う終端では、終端の stage と `deadletter_pending = true` を保存してから、deadletter を書きます。書けたら `deadletter_pending` を消して保存します。書けなければ true のまま残し（`outbound_deadletter_write_failed`）、起動時と各 tick（一時停止中も）で書き直します。どの場合も送り直しません。書けたあとで `deadletter_pending` を消す保存に失敗すると、deadletter が重なることはありますが、送信は増えません。

### 9.5 DB の入れ替えとソースの変更

- Messages の DB が入れ替わったら、外部依頼の未完了をすべて `outbound_db_reset` で終端にして保存します。そのあとで、作業用のメモリ（解決結果、保留）を捨てます。ledger は消しません。この保存に失敗したら、外部依頼の送信を止めます。
- 入れ替えやソースの変更の前に始めた send の結果があとから戻っても、GUID を `sentGUIDs` に入れることのほかは何もしません。stage も進めず、次の送信も始めません。

### 9.6 上限と state の破損

- ledger は、依頼の記録と別名を合わせて最大100000件です。上限に達したら、**新しい予約だけ**を止めます（`outbound_ledger_full`）。取得は続け、既存の未完了（再起動後の本文の取り直しを含む）は続けます。新しい行は記録も終端もしないので、cursor はその行を越えて進めません。古い記録を消して続けることはしません。
- state が壊れたり無くなったりしたときに、以前の冪等の履歴を戻せるとは保証しません。運用を始めたあとに、state を消して機能を再開してはいけません。戻すときは機能をオフにし、オーナーがバックアップと未配送の状況を確かめます。

## 10. ログと秘匿

### 10.1 秘匿の範囲

禁止するのは、**外部依頼が足す情報と、外部依頼が原因で残る記録**（アプリのログ、deadletter、保存する JSON）だけです。

- ログと deadletter
  - `chatID`、`guid`、`rowid` は nil にする。
  - 本文、宛先の GUID、ハンドル、participant、電話番号、メール、Notion の ID、ページ ID、キー、各ハッシュ、GIF の実際のパスを出さない。
  - deadletter の kind は `outbound`。detail は件数か、既存の決まった理由だけにする。
- 対象外：main からある `known_chats`（宛先の解決に要る chat の一覧）と `sent_guids`（送ったメッセージの GUID。受信時のエコー抑止に要る）は、生の値が要るので変えません。外部依頼の送信でも `sent_guids` に送信メッセージの GUID が増えますが、宛先の GUID ではありません。OB36 はこの2つを除いた外部依頼の記録を検査します。
- 保存する JSON
  - 本文、ハンドル、participant、ページ ID とキーの生の値、宛先 GUID の生の値を入れない（ハッシュと chat_id は入れてよい）。
- 共通化した送信処理を通っても、`reply_sent` などに実際の GUID を渡しません。外部依頼のときは、値を含まない `outbound_*` のコードで記録します。
- 既存の snapshot の `enabledChatIDs`、`haltedChatIDs`、`configChatIDs` などはそのままです。新しい項目は足しません。

### 10.2 コード一覧

| コード | level | 意味 |
|---|---|---|
| `outbound_source_invalid`、`outbound_source_conflict` | error | 専用 ID が不正、または返事用と同じ |
| `outbound_fetch_failed` | error | 取得か応答の失敗 |
| `outbound_token_missing` / `_mode` / `_empty` / `_unreadable` | error | トークンを使えない |
| `outbound_bad_entry`、`outbound_unknown_target`、`outbound_empty_body`、`outbound_signal_body`、`outbound_text_invalid` | warning | 行を送らずに終端 |
| `outbound_expired` | info | 期限切れ |
| `outbound_target_unset`、`outbound_target_collision` | error | 宛先の設定が無い、または衝突している |
| `outbound_family_not_configured`、`outbound_family_not_group`、`outbound_self_not_self` | error | 宛先の資格が無い |
| `outbound_target_ambiguous`、`outbound_held_unverified` | warning | 一覧で解決できないので保留 |
| `outbound_chat_disabled`、`outbound_target_changed`、`outbound_source_changed`、`outbound_db_reset` | info | 許可・宛先・ソース・DB が変わったので終端 |
| `outbound_guid_mismatch` | error | 送信直前の GUID の不一致 |
| `outbound_duplicate_key`、`outbound_duplicate_body` | info | 重複を抑止した |
| `outbound_idempotency_conflict` | error | キーの内容が衝突した、または再起動後に取り直した内容が署名と違う |
| `outbound_ledger_full`、`outbound_state_save_failed`、`outbound_deadletter_write_failed` | error | 記録の上限、保存の失敗 |
| `outbound_marker_sent`、`outbound_body_sent` | info | 空でない GUID を得た。配送の確認ではない |
| `outbound_send_failed`、`outbound_send_uncertain`、`outbound_send_interrupted` | error | 1通目で終端 |
| `outbound_body_send_failed`、`outbound_body_send_uncertain`、`outbound_body_send_interrupted` | error | 本文で終端（送り直さない） |
| `outbound_held_locked`、`outbound_held_not_started`、`outbound_held_rate_limited`、`outbound_held_body_unavailable` | warning | 送信を保留 |

- GIF の `marker_image_unavailable` と `marker_image_failed` は共通のコードを使いますが、識別子は付けません。
- 設定、取得、保留が続く障害は `NoticeLogGate` で重ねません。原因が解消したあとにまた起きたら、もう1件記録します。行の拒否は、その行が最初に終端になったときだけ記録します。

## 11. 伝書鳩の切り替え手順

この手順は実装後に段階ごとに進めます。この修正作業では実施しません。

### 担当

- オーナーは各段階の合格を承認し、1対1へ逃がすかを決めます。
- 伝書鳩の担当は Notion の行を作り、再試行します。Linq からの送信停止と切り替えも担当します。
- Mac mini の操作担当は Genie の一時停止、トーク一覧の確認、`config.json` の変更、再開を行います。

トークン、データソース ID、宛先 GUID、本文などの値を PR、Issue、チャットに貼りません。設定ファイルは `chmod 600` にします。

### 手順

1. オーナーは返事用とは別の Notion データベースを作ります。列は `idempotency_key`（title）、`target`（rich_text）、`text`（rich_text）、`created_at`（created_time）の4つです。
   - **合格。** 4列の名前と型が一致し、返事用データベースと分かれています。
   - **戻し方。** 列が違えば行を作らず、データベースを未共有のまま直します。
2. オーナーは Genie の内部連携に読む権限だけを与えます。伝書鳩の担当には行を作る接続を用意します。
   - **合格。** Genie はデータソースを query でき、伝書鳩の担当は行を作れます。
   - **戻し方。** 権限が違えば接続を使わず、オーナーが共有設定を直します。
3. Mac mini の操作担当は Genie を一時停止し、SPEC 4.11 の読み取り専用コマンドとチャット一覧を照合します。
   - **合格。** `self` が自分宛ての一意なトーク、`family` が一意なグループと確認でき、両方の GUID が許可設定に一致します。値は記録や報告に残しません。
   - **戻し方。** 一致しない、重複する、または判定できない場合は設定を進めず、一覧と許可設定を直して手順3からやり直します。
4. Mac mini の操作担当は一時停止したまま、`config.json` に専用 ID と `outbound_targets.self` だけを書きます。`family` はまだ設定しません。
   - **合格。** 設定を再読込でき、専用 ID の矛盾がなく、自分宛てがメニューで許可されています。
   - **戻し方。** 不備があれば一時停止したまま `outbound_notion_data_source_id` を空にし、設定の再読込を確かめます。state と ledger は消しません。
5. オーナーの自分宛て送信の OK を得てから、Mac mini の操作担当は Genie を再開します。伝書鳩の担当は `self` の試験行を1件作ります。
   - **合格。** Messages で目印と本文の2通を確認し、同じ依頼の追加送信がありません。ログと deadletter に本文や識別値がありません。
   - **戻し方。** 試験を止めて Genie を一時停止し、オーナーが Messages で到着を確認します。結果が分からなければ1対1へ自動転送しません。
6. 伝書鳩の担当は `self` のまま、同じキーの別ページ、同じページの編集、別キーで同じ本文（600秒以内）、再起動後の各ケースを確認します。
   - **合格。** いずれのケースでも新しい送信が増えません。
   - **戻し方。** 追加送信があれば行作成を止め、Mac mini の操作担当は Genie を一時停止して手順4の方法で外部依頼を無効にします。オーナーが履歴を確認するまで再開しません。
7. オーナーは家族に知らせ、家族グループへの初回送信を承認します。Mac mini の操作担当は Genie を一時停止し、`outbound_targets.family` と `group_chat_guids` を設定します。
   - **合格。** `family` が一意のグループと確認でき、実効許可があります。承認前に試験行は作りません。
   - **戻し方。** 不一致や判定不能があれば一時停止のまま `outbound_notion_data_source_id` を空にし、手順3から確認します。
8. オーナーの切り替え承認後、伝書鳩の担当は、まず `target = family` の Notion 行で試験通知1件が届くことを確かめ、そのあとで Linq からの家族グループ送信を止めて通知を Notion 行に切り替えます（同じ通知を両方に出さない）。予定のまとめとリマインドには別々のキーを使います。
   - **合格。** 家族グループへの試験通知1件が Messages に届き、Linq と Genie の二重送信がありません。
   - **戻し方。** 伝書鳩の担当は行作成を止め、Mac mini の操作担当は Genie を一時停止して専用 ID を空にします。403 が続いた Linq の送信は自動で再開しません。
9. 既存の1対1への逃がしは手動で残します。オーナーは、伝書鳩の担当が行を作れなかった場合、または Messages で未着を確かめた場合に、通知ごとに使うかを決めます。伝書鳩の担当は承認を得てから1対1へ一度だけ送ります。
   - **合格。** オーナーが Messages で未着を確認し、同じ通知が家族グループに届いていないと判断してから送ります。
   - **戻し方。** 到着が不明なら1対1へ送りません。時間経過、cursor の前進、`outbound_body_sent` だけを到着確認として扱いません。

### 伝書鳩の担当が行を作る前に確認すること

- `target` は小文字の `family` または `self` と完全一致させます。
- 4列を1回の行作成で揃えます。`created_at` は Notion が設定します。
- 本文を `🪔` で始めません。先頭の空白、不可視文字、VS16 があっても検証されます。
- 本文を8000 Unicodeスカラー以内にします。
- 作成から15分以内に処理される行を作ります。期限切れの通知を新しいキーで再作成しません。
- 同じ通知を再試行するときは `idempotency_key` を変えません。

Genie は結果を伝書鳩へ返しません。行を作れたこと、cursor が進んだこと、`outbound_body_sent` は端末への到着を証明しません。ログと deadletter は理由と件数だけで確認します。値は記録しません。

state と ledger は消しません。旧版へ戻す場合は、停止直後の state を保管し、旧版で新しい state 項目が消えないようにします。再有効化は、履歴と未完了を確認したうえでオーナーが決めます。

## 12. 実機（Mac mini）で確かめること

以下は Linux の Core テストでは確かめられません。モックや FakeSender で通っても、実機で確かめたとは書きません。自分宛てでの実送信の前と、家族グループへの初回送信の前に、それぞれオーナーの OK が要ります。

1. 読むだけの内部連携で新しいデータソースを query できること。行が見えるまでの遅れ、時刻の丸め、120秒の読み直しで足りるか。
2. 本番の `ImsgMessageSender` が、`Process.executableURL` と引数配列のまま、GIF（`--file`）と文字（`--text`）を渡していること。
3. 同梱の GIF が画像だけの1通として届き、空でない GUID が返ること。GUID が返らないときに本文が足されないこと。
4. GIF を使えないとき、カスタムの `reply_marker` と本文が届くこと。家族の端末で GIF が動き、本文と順に並ぶこと。GIF が `.failed` で文字に切り替えたとき、GIF と文字の目印の両方が届くことがある（`.failed` は未配送を確定しないため）。起きたら、両方が届いたかどうかだけを記録する。
5. 自分宛てと家族グループで、GUID、グループかどうか、自分宛ての根拠を照合できること。`imsg chats`、chat.db、watch の GUID の形が同じであること。実際の値は報告しない。
6. ロック中、解除、-1712、タイムアウト、停止と再起動のときの実際の動き。本文が `.failed` のときも結果が分からないときも、送り直さないこと。
7. フルディスクアクセス、Messages のオートメーション、署名したあとの子プロセスの起動。
8. 引用符、改行、バックスラッシュ、`$()`、バッククォート、`--chat-id` に似た本文が、そのまま文字として届くこと。自分宛てで先に確かめる。
9. アプリのログと deadletter に、本文、GUID、宛先の実際の値、ハンドルが無いこと。あるか無いかだけを報告する。
10. 通常の返事と通知が重なったときの順序、既定の1分5件、1時間前のリマインドの遅れが、運用に合っていること。

## 13. GREEN 一覧

### 13.1 テストの作り方

- テストはすべて `Tests/GenieCoreTests` に置き、Linux の `swift test` で動かします。AppKit は import しません。
- 本番と同じ入口を通します。テストだけの送信入口は作りません。
  - 取得と送信: `GeniePoller.tick()`、`Engine.pollOutbound()`、`retryHolds()`
  - 受信: `ingestWatchLine`
  - 起動: 保存した JSON から新しい Engine を作る
- 時間と順序は次で決めます。
  - Core の時間は `ManualClock` で進める。実時間の sleep や空回しのループは使わない。
  - 競合は `Gate` と probe で作る。
  - 共有の間隔管理のテストでは、待ちを外から解ける sleeper を差し込む。
  - 実際のプロセスを使う既存の契約テスト（OB42、OB43）は、プロセスの終了を待つ。
- 観測は次で行います。
  - 送信は `FakeSender.outgoing`、webhook は `FakeWebhook` を使う。
  - 保存は、どの保存で失敗させるかを選べる store（`ScriptedSaveStateStore`。n 回目か、条件に合う保存で失敗）と `RecordingStateStore` を使う。
  - Notion は `DatasetNotion` と同じ形の transport に、生の JSON を渡す。
- 送信0回のテストでは、`sender.outgoing` が空であることを確かめます。拒否のケースには必ず、条件を直すと送れる「正の対照」を同じテストに入れます。
- テストのメソッド名は `testOBnn` で始めます。manifest の `filter` には、1つのテストの名前を書きます。

ファイルの略号は次のとおりです。

| 略号 | ファイル |
|---|---|
| C | `OutboundConfigTests.swift` |
| N | `OutboundNotionTests.swift` |
| A | `OutboundAuthorizationTests.swift` |
| S | `OutboundSendTests.swift` |
| I | `OutboundIdempotencyTests.swift` |
| P | `OutboundPrivacyTests.swift` |
| R | `OutboundPollerTests.swift` |

「新規」は基点 `71be743` に無い動きのことで、基点では落ちるかコンパイルできません。「回帰」は基点でも通る動きです。

### 13.2 新規

| ID | GREEN when | 区分・ファイル | 落とす変異 |
|---|---|---|---|
| OB01 | 新しいキーが無い・null・空のとき、外部依頼の fetch も send も0回。同じ tick で既存の返事は送られる | 新規 C、R | なし（テストだけ） |
| OB02 | 型違い、未知の target キー、文字列でない値、`outbound_max_age_seconds` が 59・3601・小数のとき、`config_unreadable` になり直前の設定を保つ。返事用と同じソース・不正な ID では外部依頼だけ無効。`config.example.json` を読むと無効の既定値になる | 新規 C | なし |
| OB03 | family が「`group_chat_guids` にある・一覧でグループ・許可がある」なら、route も `in_reply_to_guid` も無しで GIF と本文の2件だけを送る | 新規 A | なし（OB06・08 の正の対照） |
| OB04 | self は、participant の根拠でも、グループでない `self_chat_ids` の根拠でも、2件だけを送る | 新規 A | なし（OB07 の正の対照） |
| OB05 | 未知の target（`Family`、`family `、`group`）と、設定していない target では、画像も文字も0回 | 新規 A | `ob05-accept-target.patch` |
| OB06 | `group_chat_guids` に無いグループは、メニューで許可していても0回。family にグループでないトークを指定しても0回 | 新規 A | `ob06-skip-family-qualification.patch` |
| OB07 | self にグループ（`self_chat_ids` に入れても）や普通の1対1を指定すると0回で終端。判定できないときは保留し、期限で終端 | 新規 A | `ob07-skip-self-proof.patch` |
| OB08 | 実効の許可がオフだと0回。メニューだけで許可した、`outbound_targets` に無いトークへは送らない | 新規 A | `ob08-skip-allowlist.patch` |
| OB09 | family と self が同じ GUID（大文字小文字だけ違う場合を含む）なら両方0回。一覧の2つのトークに同じ GUID があると保留して0回。大文字小文字だけ、またはサービス部分（`any;+;`、`SMS;+;`）だけ違う GUID は解決しない | 新規 A | `ob09-first-match.patch` |
| OB10 | DB の入れ替えリセットが起きないまま GUID だけ違うときと、許可元どうしで GUID が違うとき、送信直前に0回で終端 | 新規 A | `ob10-skip-guid.patch` |
| OB11 | 生の JSON の行に、別のトークの `chat_id`・`guid`・`in_reply_to_guid` を足しても、解決した宛先にだけ送る | 新規 N、A | `ob11-use-row-address.patch` |
| OB12 | 1通目と本文のあいだ（Gate で止める）で次のどれかが起きたら、本文は0回で終端し、新しい宛先へ送らない。`outbound_targets` の変更、family を `group_chat_guids` から外す、機能をオフ、self の participant・自分のハンドル候補・`self_chat_ids` の変化 | 新規 A、R | `ob12-use-stale-reservation.patch` |
| OB13 | 最初の一覧の前は fetch も send も0回。一覧の失敗・空・対象が無いときは send 0回で保留し、期限内に戻れば送り、期限後なら `outbound_expired` | 新規 A、R | なし |
| OB14 | 成功時は GIF と本文の2件だけ。本文に呼び名を付けない | 新規 S | 既存の `gif-success-also-text.patch` をこのテストでも登録 |
| OB15 | GIF が `.failed` なら、カスタムの `reply_marker` の文字と本文を送る。GIF が使えないときは画像を起動しない | 新規 S | 既存の `gif-no-fallback.patch` をこのテストでも登録 |
| OB16 | GIF の `.uncertain` と空 GUID では、追加の送信が0回。再取得しても再起動しても増えない | 新規 S、I | 既存の `gif-uncertain-fallback.patch` をこのテストでも登録 |
| OB17 | GIF の `.notStarted` は保留してレートを戻し、次は GIF から試す。本文の `.notStarted` は本文の send の回数に数えず、保留のあと本文を1回だけ送る | 新規 S | 既存の `gif-notstarted-fallback.patch` をこのテストでも登録 |
| OB18 | 本文の `.failed`・`.uncertain`・空 GUID・タイムアウト・-1712 だけのどれでも、本文の send は1回だけで、送り直し0回でそれぞれのコード（`outbound_body_send_failed` / `outbound_body_send_uncertain`）で終端。実際の `SendResultParser` に生の応答（`"nope"`、空の出力、壊れた JSON、`status: failed`）を通しても、送り直し0回で `outbound_body_send_failed`。同じテストの中で、既存の返事は同じ生の応答で本文を1回送り直す（対照） | 新規 S | `ob18-retry-uncertain-body.patch` |
| OB19 | 外部依頼で送った画像の GUID・文字の目印・本文を `ingestWatchLine` へ戻すと、`ignoredSentGUID` になる。GUID が違って文面が同じ本文は120秒以内なら `ignoredFingerprint`。自分宛てトークの `is_from_me=false` で、🪔 で始まり GUID も指紋も一致しない入力は `ignoredNotFromMe` になる。普通の1対1では同じ入力が受け付けられる（正の対照）。対照を除いて webhook は0回 | 新規 S | `ob19-skip-sent-guid.patch` |
| OB20 | ロック中、一時停止、停止を、各部の直前と await のあとで守る。ロックが分からなければ試す | 新規 S、R | なし |
| OB21 | 返事と外部依頼が、同じトークでレートの枠と送信順を共有する。外部依頼の本文は枠を使わない | 新規 S、R | なし |
| OB22 | 期限の直前なら送り、ちょうど期限と期限後は、新しい依頼・保留・本文だけ（`.notStarted` の保留と再起動後を含む）のどれも send を始めない | 新規 N、S | `ob22-skip-expiry.patch` |
| OB23 | 空の本文、目印だけ、先頭の 🪔、不可視文字や VS16 付きの 🪔、整形すると 🪔 になる本文、元か整形後で8000スカラーを超える本文、NUL のどれも0回で、それぞれのコードで終端 | 新規 N、S | `ob23-skip-body-validation.patch` |
| OB24 | 同じキーの別ページは処理1回で、`outbound_duplicate_key`。同じページを再取得しても、本文やキーを編集しても、新しい処理は作らない | 新規 I | `ob24-forget-alias.patch` |
| OB25 | 同じキーで本文か target が違えば `outbound_idempotency_conflict`。元の未完了の内容はそのまま送られ、新しい行は送らない | 新規 I | なし |
| OB26 | 別のページ・別のキーでも、同じ宛先で同じ NFC 本文（NFD で書いたものを含む）は抑止する。未完了のあいだは600秒を過ぎても抑止。別の宛先は送る。新しいキーは、終端の時刻 + 599秒では抑止し、ちょうど600秒と翌日は送る | 新規 I | `ob26-skip-body-hash.patch` |
| OB27 | JSON に保存して読み直した新しい Engine で同じ行を取っても、処理は1回分のまま | 新規 I | `ob27-ignore-ledger-on-load.patch` |
| OB28 | 最初の send（Gate で止める）の時点で、最後に保存した JSON に予約がある。予約の保存が失敗すると send 0回で、cursor も進まない。fetch・保留の再試行・レート解除が重なっても処理は1回 | 新規 I | `ob28-send-before-save.patch` |
| OB29 | 保存した stage から再起動すると、9.4 の表のとおりに動く。①`marker_in_flight` は追加0回。②`body_ready` は、取り直した本文が署名と一致すれば本文だけ1回。③`body_in_flight` は0回。④「本文が成功 → 終端の保存が失敗 → 再起動」は0回。⑤「結果を受け取る前に停止 → 再起動」は0回。⑥再起動の前に元のページの本文か target を編集していたら、`reserved` でも `body_ready` でも0回で `outbound_idempotency_conflict`。⑦元のページが取れなければ0回で保留し、期限で `outbound_expired`（期限内に取れるようになれば送る正の対照を含む） | 新規 I | `ob29-retry-interrupted-marker.patch`（①）、`ob29-resume-interrupted-body.patch`（③④⑤。別のテストメソッド） |
| OB30 | `body_ready`・起動時の整理の保存が失敗すると、次の send を始めない。deadletter を書けなくても、終端の依頼を送り直さず、`deadletter_pending` が true で保存される。その JSON から読み直した新しい Engine の起動時と tick で deadletter が書き直されて `deadletter_pending` が消え、送信は0回のまま | 新規 I、S | なし |
| OB31 | 処理済み ID と seen が5000件を超えても、古い依頼を送らない。別名と合わせて100000件に達したら、新しい予約は0回で `outbound_ledger_full`、cursor は新しい行を越えない。取得は続き、既存の未完了は続き、古い記録は残る。上限の state（`body_ready` の依頼を含む）を JSON から読み直した新しい Engine で、元のページから本文を取り直して本文だけを送れる | 新規 I | `ob31-evict-ledger.patch` |
| OB32 | DB の入れ替えとソースの変更で、未完了が終端になる。あとから戻った send の結果から続けて送らない。ledger は残る | 新規 I、S | なし |
| OB33 | 不正な行（列が無い、型違い、要素の一部が壊れている、キーの形が違う、60秒を超えて未来）はページのハッシュで終端し、直しても送らない。ページ ID か `created_time` が読めない応答は取得失敗で、cursor が進まない | 新規 N | なし |
| OB34 | cursor が空なら、開始の分より前の行は送らない。通信中に分が変わって再起動しても、開始の下限は失わない。ページング、120秒の読み直し、未完了の手前で水位を止めること、返事用の2つの cursor と独立していること | 新規 N | なし |
| OB35 | 返事と外部依頼の取得が1つの間隔管理を共有する。2つ目の要求は待つ。`prepared` で作り直しても間隔を保つ。返事の取得が失敗しても、同じ tick で外部依頼を取得する | 新規 N、R | なし |
| OB36 | 成功・拒否・保留・保存の失敗・再起動を通したあとの、外部依頼が原因のログ・deadletter のシリアライズ結果に、本文・GUID・宛先・ハンドル・ページ ID・キー・ハッシュ・GIF のパスが無い。chatID・guid・rowid が nil。保存した JSON に本文・ハンドル・キーとページ ID の生の値・宛先 GUID が無い | 新規 P | `ob36-log-values.patch` |

### 13.3 回帰

| ID | GREEN when | 区分・既存のテスト | 落とす変異 |
|---|---|---|---|
| OB37 | 既存の返事の GIF の成功・確定失敗・結果不明・notStarted が、これまでどおり | 回帰 `GifMarkerTests`（`testImageSuccessSendsNoTextMarker`、`testImageFailedFallsBackToMarkerAndContinues`、`testImageUncertainSendsNothingMore`、`testImageNotStartedHoldsAndRetriesImageFirst`） | 既存の `gif-success-also-text`、`gif-no-fallback`、`gif-uncertain-fallback`、`gif-notstarted-fallback` |
| OB38 | 既存の返事の保存順、**結果不明でも本文を1回送り直すこと**、途中で止まったら1回送り直すこと、送り直しの途中で止まったら deadletter、同じトークで混ざらないこと | 回帰 `SplitReplyTests`（`testSavesHappenInOrder`、`testBodyUncertainIsResentOnce`、`testCrashDuringTheFirstBodyUsesTheOneResend`、`testCrashDuringTheResendIsDeadLettered`、`testSameChatRepliesDoNotInterleave`） | 既存の `split3`、`split8f`（SPLIT8U・SPLIT8I）、`split13`、`split31` |
| OB39 | 既存の返事も、GUID が違えば送信0回 | 回帰 `StartupSendTests.testDifferentGuidDoesNotSendWhenTheDatabaseIsNotReset` | 既存の `gc11-bypass-send-guid` |
| OB40 | HTTP と Notion の返事の cursor と処理の順序、片方が失敗してももう片方を取ること | 回帰 `JobReplyLaneTests`（G12、G13） | 既存の `job12-shared-cursor`、`job13-abort-on-source-failure` |
| OB41 | 設定のグループの許可、メニューとの和、すべての許可元の GUID 照合 | 回帰 `GroupChatTests`（GC08、GC10） | 既存の `gc08-retain-removed-intent`、`gc10-ignore-other-permission-source` |
| OB42 | 本文と画像のパスを、そのままの引数要素で渡す。対象は `ImsgCommand` の配列と Core の `ProcessRunner` まで | 回帰 `GroupTransportTests.testBodyIsOneLiteralArgumentAndEchoDoesNotInterpretIt`、`GifMarkerTests.testFileArgumentsAreLiteralAndHaveNoText` | 既存の `gc20-shell-command`、`gif-file-shell` |
| OB43 | 次の2つが両方通る。(a) 検査器の見本のテスト: 架空の見本が通り、個人の電話番号を検出する。(b) 追跡したファイル全体への `python3 scripts/check-tracked-text.py` の実行（13.5 の3。`swift test` では全体を検査しないので、別に実行する） | 回帰 (a) `TrackedTextTests.testGroupDocumentationDummiesPassAndPersonalPhoneIsDetected`、(b) 完了条件のコマンド | (a) 既存の `gc23-skip-phone-check`。(b) は変異なし |

OB43 の (b) は、追加した仕様・fixture・パッチを**追跡対象にしたあとで**実行します。検査器が見ない GUID などは、レビューで架空の値（`chat000000000000000001`、`example.com`、`0000`）であることを確かめます。

### 13.4 新しい変異（20本）

どれも、実装の中の判定か保存の境界を1つだけ壊すものです。

| パッチ | 壊すこと | filter |
|---|---|---|
| `ob05-accept-target.patch` | 未知の target を family として受け付ける | OB05 |
| `ob06-skip-family-qualification.patch` | family の `group_chat_guids` とグループの確認を省く | OB06 |
| `ob07-skip-self-proof.patch` | self の「グループでない」と根拠の確認を省く | OB07 |
| `ob08-skip-allowlist.patch` | 実効の許可の確認を省く | OB08 |
| `ob09-first-match.patch` | 2件以上一致しても最初のトークを選ぶ | OB09 |
| `ob10-skip-guid.patch` | 送信直前の許可元の GUID 照合を省く | OB10 |
| `ob11-use-row-address.patch` | 行の `chat_id` 列を宛先に使う | OB11 |
| `ob12-use-stale-reservation.patch` | 本文の直前の確かめ直しを省き、1通目の解決結果を使う | OB12 |
| `ob18-retry-uncertain-body.patch` | 外部依頼の本文に返事の `BodyResendPolicy` を使う | OB18 |
| `ob19-skip-sent-guid.patch` | 外部依頼の送信 GUID を `sentGUIDs` に入れない | OB19 |
| `ob22-skip-expiry.patch` | 各 send の直前の期限の確認を省く | OB22 |
| `ob23-skip-body-validation.patch` | 元の本文の 🪔 の拒否を省く | OB23 |
| `ob24-forget-alias.patch` | ページ ID の別名を保存しない | OB24 |
| `ob26-skip-body-hash.patch` | 同じ宛先・同じ本文の抑止を省く | OB26 |
| `ob27-ignore-ledger-on-load.patch` | 読み込んだ `outbound` 領域を捨てる | OB27 |
| `ob28-send-before-save.patch` | 予約の保存結果を待たずに send を始める | OB28 |
| `ob29-retry-interrupted-marker.patch` | `marker_in_flight` を再起動のあとに送り直す | OB29 ① |
| `ob29-resume-interrupted-body.patch` | `body_in_flight` を再起動のあとに `body_ready` として送り直す | OB29 ③④⑤ |
| `ob31-evict-ledger.patch` | 上限に達したら古い記録を消して続ける | OB31 |
| `ob36-log-values.patch` | 外部依頼のログに chatID と GUID を渡す | OB36 |

- 文書の文言だけを壊す変異は作りません。文書はレビューで確かめます。
- 表に変異が無い GREEN も、テストは残します。
- 既存の変異 `gif-success-also-text`、`gif-no-fallback`、`gif-uncertain-fallback`、`gif-notstarted-fallback` は、manifest に別の name で OB14〜17 の filter でも登録します。これが外部依頼の側で KILLED にならなければ、共通の送信処理を通っていないということです。
- 既存の `gc11-bypass-send-guid`、`gc20-shell-command`、`gif-file-shell`、`gif-*`、`split*` が共通化のせいで当たらなくなったら、壊す意味を保ったまま直します。

### 13.5 完了条件

1. PR #26 では新規テストが基点 `71be743` で失敗することを確認しました。
2. PR #26 取り込み後、Linux の全体 `swift test` は失敗0件でした（2026-11-17 の確認。以後の変更では取り直す）。3.4 に記録した2件も成功します。
3. `python3 scripts/check-tracked-text.py` を、新しいファイルを追跡対象にしたうえで、追跡したファイル全体に対して通す（OB43 の (b)）。
4. 新規と既存のすべてのパッチで、`git apply --check` を通す。
5. `python3 tools/check-mutants.py --probes` と `python3 tools/check-mutants.py` を通す。**すべての変異が KILLED であること。**
   - KILLED と数えるのは、指定したテストが**アサーションの失敗で**落ちたときだけ（`XCT… failed` の行と `Test Case '…' failed` の両方が出ること）。
   - throw されたエラー（`ERRORED`）、クラッシュ（`CRASHED`）、ビルドの失敗、実行されたテストが0件は、殺したと数えない（PR #26 の教訓）。
   - そのため、変異を `try XCTUnwrap` の throw、`fatalError`、強制アンラップで検出するテストにはしない。変異が入ると、`XCTAssertEqual` などの値の比較が落ちるように書く。
6. 実機での確認（12章）は別に記録し、Core のテストが通っただけで配送を確かめたとは書かない。

## 14. SPEC.md・README・config.example.json への反映

### 14.1 SPEC.md

**4.3 への追記**
> 外部依頼（4.12）の途中経過は `pending_sends`・`partial_replies` ではなく state の `outbound` 領域に置く。DB の入れ替えでは外部依頼の未完了を `outbound_db_reset` で終端にして保存し、作業用の記録を捨てる。永続の冪等記録（ledger）は消さない。

**4.4 への追記**
> 2通の送信処理は、返事と外部依頼で共有する。外部依頼の本文にはグループの呼び名を付けない。外部依頼の本文は一度も送り直さない。`SendResultParser` は読めない応答・空の出力・未知の応答も `.failed` にするので、`.failed` も結果不明・空 guid・途中停止と同じく deadletter で終端する（`.notStarted` だけは保留して数えない。4.12）。1通目の GIF `.failed` から文字への切り替えは決定24のままで、GIF と文字の両方が届くことがある。返事の本文の送り直しは、この節のまま。外部依頼で送った画像・文字・本文の guid も `sentGUIDs` に入れ、文字と本文に指紋を付ける。

**4.9 への追記**
> `outbound_notion_data_source_id`（文字列、既定 `""`、空なら無効）、`outbound_targets`（`family`・`self` だけを持つオブジェクト、既定 `{}`、許可にはならない）、`outbound_max_age_seconds`（整数、既定 900、60〜3600）。型違い・未知キー・範囲外は `config_unreadable`。同じ本文の抑止は600秒の固定値で、設定にしない。

**4.12 外部からの送信依頼（新設）**
> 専用の Notion データソースの行を、`family` と `self` のどちらかへ2通で送る。送り先は設定の GUID と最後に成功した一覧との完全一致で、候補がちょうど1件のときだけ決める。`ConfigGroupAuthorization` の最初の一致は使わない。family は現在の `group_chat_guids` にありグループであること、self はグループでなく participant か `self_chat_ids` で自分宛てと確かめられることが条件。実効の許可、すべての許可元の GUID 照合、期限、一時停止・停止・ロックを各部の直前に確かめ直す。self の根拠が1通目と本文のあいだで変われば送らない。行の chat_id・guid 列は使わない。本文の send は依頼1件につき最大1回で、送り直さない。ledger（キーとページ ID の別名は永久、同じ宛先・同じ本文は終端から600秒の抑止）と、保存済みの stage による再開で重複を防ぐ。判断は最後に保存できた state で行い、本文が成功したあと終端の保存に失敗して再起動しても送り直さない。再起動後は本文を元のページから取り直し、保存済みの署名と違えば送らずに終端、取れなければ保留して期限で終端する。ledger が上限なら新しい予約だけを止める。ログ・deadletter・保存する JSON に、外部依頼が足す値を出さない。詳しくは `docs/outbound-send.md`。

**5.5 送信依頼専用 Notion データソース（新設）**
> 列は `idempotency_key`（title）、`target`、`text`（rich_text）、`created_at`（created_time）。`outbound_notion_cursor` は返事用の cursor と独立。初回は取得開始時の分の先頭を、通信の前に保存する。読み直しは120秒、最大20ページ、件数の枠は `reply_page_limit`。間隔管理は返事と1つを共有する。不正な行はページのハッシュで終端し、ページ ID か作成時刻が読めない応答は取得失敗にする。権限は読むだけで、結果は書き戻さない。

**9章** に「外部送信依頼の実機確認」の小節を足します。中身はこの文書の12章の10項目で、ここへのリンクを付けます。

**決定25（案）**
> 25. 外部からの送信依頼（2026-11-16、オーナーの承認）。伝書鳩の予定のまとめと1時間前のリマインドを、返事用とは別の Notion データソースから Genie が取って送る。専用の設定が空なら無効。設定は専用 ID、限定した宛先、期限の3つ。行の送り先は `family` と `self` だけで、実際の GUID は Mac mini の設定にだけ置く。family は設定で許可して一覧でグループと確かめたトーク、self はグループでなく自分宛てと確かめたトークだけ。1通目は決定24、本文には呼び名を付けない。外部依頼の本文は、失敗・結果不明・途中停止のどれでも送り直さない（`.failed` は未配送を確定しないため）。既存の返事の決定20〜24は変えない。冪等キーは `idempotency_key` 1つとページ ID の別名で、どちらも永久に1回。別のキーの同じ宛先・同じ本文は終端から600秒抑止し、それを過ぎた新しいキーの同じ本文は送る。期限を過ぎたものは送らず、履歴は自動では消さない。伝書鳩と Job Engine の変更と実送信は別の作業で、自分宛ての試験、家族グループへの初回、伝書鳩の切り替えは、それぞれオーナーの OK のあとに行う。家族の 🪔 を Job Engine へ渡す承認とは別。

既存の決定20〜24の本文はそのまま残します。

### 14.2 README

設定の説明に、次を足します。

- 外部依頼は返事とは別の Notion データソースを使い、既定は無効であること。新しい3つのキーと、架空の例（4.4）。
- 行の4列、全部を揃えて一度に作ること、編集しても送り直さないこと、キーは通知ごとに決めて再試行では変えないこと。
- `family` と `self` にしか送れないこと。`outbound_targets` は許可にならないこと。family と self の条件。
- GIF か文字の目印と本文の2通で送ること。本文は送り直さないこと（送れなかったら deadletter とログに残る）。GIF が失敗して文字に切り替えたとき、目印が2つ届くことがあること。
- 既定15分の期限、同じ本文の600秒の抑止（それを過ぎた新しいキーの同じ本文は送る）、履歴を自動では消さないこと、state を消さないこと。
- 配送結果を伝書鳩へ返す機能は無いこと。確かめ方は Messages とログ（11章）。
- 無効にする手順（一時停止、ID を空にする、確かめてから再開）。
- 自分宛てから始めること、各段でオーナーの OK が要ること、実機で未確認の項目（この文書の12章）。

既存の返事の route 必須、返事用の cursor、Job の設定、`reply_marker` の説明は変えません。

### 14.3 config.example.json

次の3つだけを足します。無効の既定値です。

```json
{
  "outbound_notion_data_source_id": "",
  "outbound_targets": {},
  "outbound_max_age_seconds": 900
}
```

OB02 で、このファイルが読めて、外部依頼が無効になることを確かめます。
