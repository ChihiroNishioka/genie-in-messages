# 家族グループの 🐦 で伝書鳩に聞く（dove トリガー）

実機での確認項目は12章にまとめています。受け口ルーチンの更新は別作業です。

## 1. 目的とオーナーの依頼

> linqのインバウンド止めちゃったから、Mac経由で家族チャット見張って、🐦の文字が来たら伝書鳩経由で家族チャットに返事するようにして

伝書鳩はこれまで Linq の番号で家族の依頼を受けていましたが、その受信は止まっています。代わりに Genie（Mac mini の常駐アプリ）が家族のグループを見張ります。先頭が 🐦 のメッセージが来たら、今の webhook（Grok Bot の受け口ルーチン）へ `trigger: "dove"` を付けて渡します。ルーチンは伝書鳩に答えを作らせ、今の Notion『genie-in-messages 返事』DB に1行書きます。Genie はその行を取り、同じグループに 🐦 の印と本文の2通で返します。

伝書鳩の Linq 番号から返すやり方（SPEC 5章の C 案）は、別の番号になって同じトークに返せないため使いません。

## 2. 範囲

### 2.1 含めるもの

- 新しい設定キー `dove_chat_guids` と、矛盾したときの扱い（4章）。
- 受信の判定。dove の対象トークで、先頭が 🐦（U+1F426）のメッセージを拾う（5章）。
- 今の webhook への POST に `trigger` を足す。dove は `"dove"`、通常経路の 🪔 は `"lamp"`。dove にだけ `request_text` も足す（6章）。
- 受け口ルーチンの手順（Grok Bot 向け）。今の返事 DB をそのまま使う（7章）。
- 返事の印 🐦 と2通の送信。印は Genie が自分の route から決める（8章）。
- ループ防止（9章）、冪等と再起動（10章）、ログと秘匿（11章）。
- 伝書鳩の印との衝突を防ぐため、`reply_marker` に 🐦 を入れられなくする。dove のトークへ送る外部依頼の本文が 🐦 で始まるときは終端にする（8.5、8.6）。
- テスト、変異、SPEC.md・README.md・config.example.json の更新。

### 2.2 含めないもの

- 🪔 → Grok Bot の流れ（判定、Job 経路、payload の既存キー、GIF の印、本文の送り直し）は変えない。通常経路の payload に `trigger: "lamp"` を追加し、dove のトークへの本文には8.4の検査を適用します。新版の配布前に通常の受け口を更新し、キーなしと `"lamp"` の互換性を確かめます。
- Job Engine、Job 経路の payload（`trigger` は付けない）。
- 伝書鳩とルーチンのプロンプトの変更。別の作業で、この PR には入れません。
- メニューの表示や snapshot の新しい項目。
- 自分宛てトークと1対1での dove。
- dove 専用の webhook URL や秘密。
- 返事 DB の新しい列。Notion の `trigger` 列も読みません。
- 配送の結果を伝書鳩や Notion へ返すこと。
- 🐦 を後から足した編集。今の規則どおり、edited と unsent には反応しません。

## 3. 用語

| 語 | 意味 |
|---|---|
| 🐦 | U+1F426 BIRD。Emoji_Presentation なので VS16 は要らない |
| dove | 先頭 🐦 の依頼と、その返事 |
| lamp | 先頭 🪔（U+1FA94）の依頼と、その返事（既存） |
| dove のトーク | 4.2 で有効になったトーク（chat_id の集合） |
| request_text | 依頼の本文から先頭の 🐦 を外した残り（5.2） |
| route の trigger | webhook の前に Genie が state の `routes` に保存する印。返事の送り方はこれで決める |

## 4. 設定

### 4.1 新しいキー

`dove_chat_guids` は文字列の配列で、既定は `[]` です。

- キーが無い、または null なら空にする。
- 各値の前後の空白を除き、空の値と重複を除く。照合は大文字小文字を区別した完全一致（`group_chat_guids` と同じ）。
- 配列でない値や、文字列でない要素があれば `config_unreadable` にし、直前の有効な設定を使い続ける。
- 空なら dove は無効で、🐦 は今までどおり `ignoredNoSignal` になる。

ROWID（`dove_chat_ids`）にしない理由: Messages の DB が入れ替わると、同じ ROWID が別のトークを指すことがあります。`group_chat_guids` と `outbound_targets` と同じく、guid を一覧で確かめて使います。

### 4.2 有効になる条件（許可との関係）

`dove_chat_guids` は許可を広げません。すでに設定で許可したグループに、dove の役割を足すだけです。chat_id が dove のトークになるのは、次をすべて満たすときです。

1. guid が `dove_chat_guids` にある。
2. 同じ guid が今の `group_chat_guids` にもある。
3. `ConfigGroupAuthorization` が、最後に取得できた一覧でその guid をグループと確かめている（`resolved`）。受信の行に `chat_guid` があれば、それも一致する。

メニューだけで許可したトーク、1対1、自分宛てでは dove を拾いません。返信では明示解除または一覧で非グループと確定した場合に終端にします。空一覧、対象の欠落、取得失敗、未照合は最後に確かめた対応で照合待ちにします。同じ chat_id の別 guid は既存の拒否、DB 交換は既存のリセットに従います。dove のトークでも、🪔 は今までどおり lamp として扱います。

### 4.3 矛盾したときの扱い

| 状況 | 扱い |
|---|---|
| `dove_chat_guids` の値が `group_chat_guids` に無い | その値は無効。warning `dove_chat_not_in_groups` を記録し、detail は件数だけ。`NoticeLogGate` で、続いているあいだは1回、解決したあとまた起きればもう1回 |
| `group_chat_guids` にあるが、一覧に無い、またはグループでない | dove も無効。ログは既存の `group_chat_not_found` / `group_chat_not_group` だけで、dove の分は重ねない |
| dove のトークが `job_chat_ids` にもある | 🐦 はいつも通常の `webhook_url` と `secret` へ送る（Job へは送らない）。🪔 は今までどおり Job 経路 |
| `webhook_url` が空か無効 | dove は deadletter（`webhook_not_configured` / `url_not_https`、kind は `webhook`）。Job へは切り替えない |
| dove のトークが `self_chat_ids` にもある | 既存の規則で `is_from_me=false` を無視するため、家族の 🐦 は拾えない。設定の誤りとして README で避けるよう書く。コードでは特別に扱わない |
| `reply_marker` に U+1F426 がある（どこにあっても） | 無効の値として既定の 🧞‍♂️ に戻し、`reply_marker_invalid`（既存）を記録する。🕊️（U+1F54A）は今までどおり有効 |
| `outbound_targets.family` が dove のトーク | 使ってよい。ただし 🐦 で始まる本文は終端にする（8.6） |
| 一時停止中 | lamp と同じく `deferredPaused`。カーソルは進めず、解除後に処理する |

### 4.4 架空の設定例

```json
{
  "group_chat_guids": ["iMessage;+;chat000000000000000001", "iMessage;+;chat000000000000000002"],
  "dove_chat_guids": ["iMessage;+;chat000000000000000001"]
}
```

この例では chat000…001 で 🐦 と 🪔 の両方が使え、chat000…002 では 🪔 だけが使えます。`config.example.json` は `"dove_chat_guids": []` にします。

## 5. 受信の判定

### 5.1 判定の順序

`GenieEngine.handle(_:)` の順序は次のとおりです。空行を除き、一時停止中は JSON の解釈前に `deferredPaused` を返します。

1. DB の入れ替えの検知
2. edited / unsent → `ignoredMutation`
3. タップバック → `ignoredReaction`
4. 送った guid（`sentGUIDs`）→ `ignoredSentGUID`
5. 処理済みの guid → `duplicate`
6. 指紋 → `ignoredFingerprint`
7. 目印（`reply_marker` と既定の 🧞‍♂️）→ `ignoredReplyMarker`
8. 先頭が 🪔 → lamp。ここから先は今の処理のまま
9. 先頭が 🐦（5.2）→ dove の候補
   1. chat_id が dove のトークでなければ `ignoredNoSignal`（dove 以外のトークでは、🐦 はただの文字）
   2. 自分宛ての受信側を無視する既存の判定（`SelfChat.ignoresInboundEcho`）を当てる
   3. `request_text` が空（`TextNormalizer.isBlank`）なら、新しい `IngestResult.ignoredEmptyDove`（finish して処理済みにする）
   4. guid が空なら `ignoredMissingDoveGUID` で処理を終える。POST と route 保存は行わない
   5. 6章の POST
10. どれにも当たらなければ `ignoredNoSignal`

判定は、先頭の飛ばせない最初のスカラーで決まります。そのため1つのメッセージが 🪔 と 🐦 の両方に当たることはありません。`🪔🐦…` は lamp、`🐦🪔…` は dove です。

送信者は誰でもかまいません。グループのメンバーなら、オーナー本人（`is_from_me=true`）も家族（`is_from_me=false`）も同じに扱い、送信者ごとの許可はありません。

### 5.2 `DoveSignal.scan`

`Sources/GenieCore/Signal.swift` に置き、先頭を飛ばす関数は `Signal` と共有します（`isSkippableLeading`。空白と改行、`TextNormalizer.isInvisible`）。`Signal.scan` の動きは変えません。

1. NFC にする。
2. 先頭の空白と不可視文字を飛ばす（🪔 と同じ）。
3. 次のスカラーが U+1F426 でなければ、当たらない。
4. 直後の U+FE0F は、あれば1つ外す。
5. 次のスカラーが U+200D（ZWJ）なら当たらない。🐦‍⬛（黒い鳥）と 🐦‍🔥（不死鳥）は別の絵文字です。
6. 続く空白と改行（U+3000 を含む）を外す。残りが `request_text`。

途中や末尾の 🐦（`おはよう🐦`、`今日は 🐦`）には反応しません。`request_text` は先頭だけを外したもので、本文の途中は変えません。

## 6. webhook の payload

### 6.1 送り先と、変わらないこと

- dove はいつも通常の `webhook_url`、`secret`、Bearer、`URLSession` の今の設定で送ります。`job_chat_ids` は見ません。
- `v` は 1、`event` は `"message"`、`idempotency_key` は guid です。再送、バックオフ、`webhook_max_attempts`、deadletter（kind `webhook`）は今のとおりです。
- `sender_name` と `sender_handle` は通常経路の規則のままです。設定のグループの家族なら正規化したハンドルが入ります。本人と自分宛てには入りません。
- 1回目の POST の前に、route（guid → chat_id、addressee、照合済みトーク GUID の SHA-256、`trigger: "dove"`）を保存します。保存できなければ `.blocked` です（今の順序と同じ）。
- 同じキーで POST を再試行し、受理後から finish の保存前に再起動した場合にも同じキーで再送できます。DB の入れ替えを検知した場合は古い行の再試行を止めます。試行のたびに `refreshConfig` し、一時停止と、そのトークがまだ dove のトークかを確かめ直します。外れていたら info `webhook_chat_disabled`（detail `dove`）を記録し、`ignoredNotAllowed` で終えます。trigger は最初に決めたものを使い続け、lamp には切り替えません。
- 成功のログは `webhook_delivered`（detail `dove`）です。

### 6.2 足すキー

| キー | dove | lamp・通常経路 | lamp・Job 経路 |
|---|---|---|---|
| `trigger` | `"dove"` | `"lamp"` | 付けない（Job Engine は知らないキーを 400 にするため） |
| `request_text` | 5.2 の残り | 付けない | 付けない |

`text` は今までどおり、NFC にした全文（🐦 を含む）です。受け口は、`trigger` が無ければ lamp とみなします（後方互換）。キーの順に意味はありません。

### 6.3 完全な例（値はすべて架空）

家族が dove のトークから送った場合:

```json
{
  "v": 1,
  "event": "message",
  "idempotency_key": "00000000-0000-0000-0000-000000000001",
  "guid": "00000000-0000-0000-0000-000000000001",
  "chat_id": 7,
  "text": "🐦 明日の集合は何時？",
  "created_at": "2026-11-21T00:00:00Z",
  "sender_is_me": false,
  "sender_name": "family",
  "sender_handle": "tel:+15550100000",
  "trigger": "dove",
  "request_text": "明日の集合は何時？"
}
```

オーナー本人が送った場合（`sender_handle` は付きません）:

```json
{
  "v": 1,
  "event": "message",
  "idempotency_key": "00000000-0000-0000-0000-000000000002",
  "guid": "00000000-0000-0000-0000-000000000002",
  "chat_id": 7,
  "text": "🐦️ 今週のゴミの日",
  "created_at": "2026-11-21T00:01:00Z",
  "sender_is_me": true,
  "sender_name": "me",
  "trigger": "dove",
  "request_text": "今週のゴミの日"
}
```

lamp の通常経路（今の payload に `trigger` だけが増えます）:

```json
{
  "v": 1,
  "event": "message",
  "idempotency_key": "00000000-0000-0000-0000-000000000003",
  "guid": "00000000-0000-0000-0000-000000000003",
  "chat_id": 42,
  "text": "🪔 天気は？",
  "created_at": "2026-11-21T00:02:00Z",
  "sender_is_me": false,
  "sender_name": "family",
  "trigger": "lamp"
}
```

lamp の Job 経路は今のままで、9キーまたは10キーです。`trigger` は付けません。

## 7. 受け口ルーチン（Grok Bot）の手順

この章は Grok Bot 側のプロンプトを書く人向けです。Genie はこの手順を強制できないので、Genie 側の守り（8章）と二重にしています。

1. 認証と `v == 1` の確認は今のとおり。
2. `trigger` を読む。キーが無ければ `"lamp"` とみなす。null または `"lamp"` と `"dove"` 以外なら何もせず、行も書かない。
3. `"lamp"` なら今の手順のまま。
4. `"dove"` なら伝書鳩に頼む。
   - 渡すのは `request_text`（無ければ `text` から先頭の 🐦、U+FE0F、空白を外したもの）と `sender_name`。冪等キーはメッセージ GUID と同じ値なので受け口内に留める。
   - `sender_handle`、`chat_id`、`guid` は伝書鳩に渡さない。
   - 伝書鳩に、iMessage や Linq で自分から送らせない。外部送信依頼の DB（docs/outbound-send.md）にも書かせない。どちらも同じトークへの二重送信や、別の番号からの送信になる。
5. 伝書鳩の答えを、今の『genie-in-messages 返事』DB に1行で書く。列は今のままで、新しい列は要らない。
   - `reply_id`（title）: `dove:` と `idempotency_key` をつないだ値（例 `dove:00000000-0000-0000-0000-000000000001`）。Genie は接頭辞を判定に使わず、一意であればよい。
   - `chat_id`（number）: payload の `chat_id` をそのまま使う。別のトークの番号を書くと、Genie は送らずに捨てる。
   - `in_reply_to_guid`（rich_text）: payload の `guid`。
   - `idempotency_key`（rich_text）: payload の `idempotency_key`。
   - `text`（rich_text）: 伝書鳩の答え。先頭に 🐦 や 🧞‍♂️ を付けても付けなくてもよい（Genie が外す）。ルーチンは先頭に 🪔 を付けない。Genie は先頭の1個を外し、整形後に合図が残っていれば拒否する。
   - `created_at`: created_time で自動。
   - 全部の列を、1回の行作成で揃える（SPEC 5.1）。
6. 冪等: 同じ `idempotency_key` の webhook は再送で何度か届くことがある。受け口でキーごとの処理を直列化するか、原子的な重複排除を行い、同時再送でも行を1件だけ作る。行作成後の再試行も同じキーで重複を止める。Genie は `reply_id` で重複を止めるので、`reply_id` が違う2行は2回の返事になる。
7. 伝書鳩が答えられなかったときは、行を書かないか、短い決まった文（例「伝書鳩が答えられませんでした」）を1行だけ書く。エラーの中身、秘密、ハンドルは書かない。
8. 行の片付けは今の規則（`route_ttl_seconds` より古い行だけ）のまま。

Genie は行の値を信用しすぎません。送り先は Genie が保存した route の chat_id、印は route の trigger で決めます。行の `chat_id` は照合にしか使いません。

新版 Genie の配布前に受け口を更新します。キーなしと `"lamp"` の結果が一致し、`"dove"` で分岐し、未知値と null が拒否されることを確かめます。同じキーを並行送信して返事の行が1件であることも確かめます。

## 8. 返事の印と送信

### 8.1 印の決め方

`deliverReply` は、`in_reply_to_guid` の route を引きます（無い・期限切れなら今までどおり `reply_unrouted`）。

- `route.trigger == "dove"` なら dove の返事です。
- それ以外（キーが無い古い route を含む）なら lamp の返事で、今のまま（GIF、だめなら `reply_marker`）です。
- 行の列やトークで印を決めません。dove のトークへの 🪔 の返事は GIF のままです。
- 保留（`HeldSend`）は trigger を持ち、再試行でもそれを使います。

### 8.2 dove の返事（2通）

- 2通の方式は今のものに揃えます（決定 20〜24、`ReplyComposer`、`partial_replies`）。
- 1通目は文字の `🐦`（U+1F426 の1スカラーだけ。空白、改行、VS16 は付けない）を `imsg send --chat-id <id> --text 🐦` で送ります。GIF と `reply_marker` は使わず、`sendFile` は呼びません。GIF をやめた理由: 🪔 や 🧞‍♂️ の返事と見分けられ、大きい絵文字として見え、新しい素材が要らないためです。
- 1通目の文字の指紋は `🐦` のハッシュです。`pending_sends.marker_kind` は `text`。
- 1通目が `.failed` や `.notStarted` のときの扱いは、文字の1通目と同じです（保留、予約を戻す、結果不明では2通目を送らない）。
- 2通目は `ReplyComposer.split` に 🐦 を目印として足して作ります。
  1. 先頭の 🪔 を外す（今のまま）。
  2. 空白、不可視文字、`reply_marker`、🧞‍♂️、🐦（5.2 の走査に一致するもの）を、無くなるまでくり返し外す。
  3. 🐦‍🔥 と 🐦‍⬛ は本文に残す。空なら `reply_empty_body`、🪔 で始まれば `reply_still_matches_signal`。どちらも送らない。
- グループの呼び名（`{addressee}へ：`）は lamp と同じ規則で付けます。付けた結果が 🐦・🪔・目印で始まるときは、付けない本文にします。
- 本文の送り直し（ちょうど1回）、`body_resends`、deadletter、レート（返事1件で1回。同じトークの lamp、外部依頼と枠を共有）、同じトークの順序は、今の返事の規則のままです。

### 8.3 dove の返事は同じトークにだけ送る

- 送り先は `route.chatID` だけ。行の `chat_id` が食い違えば `reply_chat_mismatch` で捨てます（今のまま）。行に `chat_id` が無ければ route の chat_id に送ります。
- 返事の取得時、1通目の直前、2通目の直前に、そのトークがまだ dove のトーク（4.2）かを確かめます。ロックの確認から戻った後と保留再開時も確認します。明示解除・確定した資格喪失は `reply_dove_chat_disabled` で処理済みにします。一時的な照合不能は既存の保留に戻します。不一致と DB 交換では既存の拒否・リセットを適用します。
- そのほかの直前の確認（実効の許可、guid の照合、一時停止、ロック、DB の入れ替え）は今のままです。

### 8.4 dove のトークへの lamp の返事

印と本文は今のままです。ただし、1通目の前と各本文送信の直前に最新の dove 資格を確認します。組み立てた2通目が `DoveSignal` に当たる（先頭が 🐦）ときは送りません。error `reply_still_matches_dove` を記録して処理済みにします。dove のトーク以外では今と同じです。

### 8.5 `reply_marker`

U+1F426 を含む値は無効にします（4.3）。🐦 を目印にすると、`ignoredReplyMarker` が家族の依頼まで止めてしまうためです。

### 8.6 外部依頼の本文

外部依頼の送り先が dove のトークで、本文（整形の前か後のどちらか）が `DoveSignal` に当たれば、`outbound_dove_body` で終端にします。送らずに deadletter（kind `outbound`）に記録します。元本文を取り込み時に検査します。最終本文は1通目の前と各本文送信の直前にも最新の dove 資格で検査します。保留中や1通目の後に有効化した場合も適用します。伝書鳩には、通知を 🐦 で始めないよう伝えます（docs/outbound-send.md 11章に足す）。

## 9. ループ防止

1通目の印 🐦 は dove の合図そのものです。そのため、🪔 で使っている「目印で始まる文を無視する」方法は使えません。次の4つで守ります。どれも SPEC 4.4 と同じ考え方です。

1. 送った guid: 🐦 の1通目と本文の guid を `sentGUIDs` に入れます（今のまま）。dove の判定は sentGUID、処理済み、指紋の確認より後に置きます（5.1）。
2. 指紋: 文字の 🐦 と本文に、今の指紋（NFC のハッシュと時刻、120秒）を付けます。
3. 空の依頼: `request_text` が空なら依頼にしません。iPhone の側で `🐦️`（VS16 付き）として戻り、guid も指紋も合わないときでも、ここで止まります。家族が 🐦 だけを送ったときも、依頼にはなりません。
4. 本文の検査: dove の本文は 🐦 を外して組み立てます。dove のトークへの lamp の本文と外部依頼の本文も、🐦 で始まれば送りません（8.4、8.6）。

自分宛ての受信側を無視する仕組み（4.10）はそのままです。🪔 のループ防止は変えません。

## 10. 冪等と再起動

- webhook: route と trigger を、POST の前に保存します。成功、deadletter、無視のどれでも finish で処理済みの guid にし、カーソルは今の規則で進めます。POST の結果が一時エラーの場合や、受理から finish の保存までに停止した場合、同じキーで再送することがあります。受け口は7章の手順で重複を止めます。
- route の `trigger` は省略できる文字列です。`"dove"` のときだけ書き、lamp では書きません。lamp の state の JSON は今と変わりません。古い state はキーが無いので lamp として読みます。
- 返事: 処理済みの `reply_id` で重複を止めます。
  - 1通目の途中で落ちたら、今までどおり `send_interrupted` で処理済みにし、送り直しません。
  - 1通目と2通目のあいだで落ちたら、再起動のあと行を読み直し、route の trigger で dove と分かったうえで、2通目だけを送ります。
  - 2通目の途中で落ちたら、今の規則で本文を最大1回送り直します。結果不明や本文送信後に成功を保存できなかった場合、初回が配送済みなら本文が重複して届くことがあります。
- DB の入れ替えで route を捨てたあとの dove の返事は `reply_unrouted` で、送りません。
- 古い版に戻すと、`dove_chat_guids` と route の trigger は無視されます。🐦 は反応しなくなり、残っていた dove の返事は lamp の印（GIF）で送られます。新規の 🐦 依頼を止め、取得を動かしたまま未処理の返信を解消します。その後で Genie を停止して戻します。
- 同じ Apple ID で動かす Mac は1台だけ、という今の前提のままです。

## 11. ログと秘匿

- ログ、deadletter、state、メニューに本文、`request_text`、ハンドル、番号、メールを出しません。設定のトーク GUID は既存の照合用 `known_chats` と許可リストで使います。route は既存のメッセージ GUID、chat_id、時刻、検証済みの呼び名を保持します。dove の route は印と照合済み GUID の SHA-256 も保持します。既存 webhook のログと deadletter はメッセージ GUID を保持できます。新しい detail は固定語か件数です。
- 新しいコード: `dove_chat_not_in_groups`（warning、件数）、`reply_dove_chat_disabled`（info）、`reply_still_matches_dove`（error）、`outbound_dove_body`（外部依頼の終端）。dove のときは `webhook_delivered` と `webhook_chat_disabled` の detail を `dove` にし、`reply_sent` の1通目の detail を `dove` にします。
- 送信は今の `ImsgCommand` の引数配列と `Process.executableURL` だけを使います。本文はシェルを通しません。`🐦` も `--text` の1要素として渡します。
- 秘密（`secret`、`notion-token`）の扱いは今のとおりで、読み直しや 0600 も変わりません。新しい秘密は作りません。
- 実機のトーク名、ID、guid、番号、名前を、コード、テスト、文書、PR、Issue に書きません。例は架空の値だけにします（`example.com`、`0000` の並び、`iMessage;+;chat000000000000000001`）。`scripts/check-tracked-text.py` と `testPersonalIdentifiersStayOutOfDocsAndTests` を通します。

## 12. 実機（Mac mini）で確かめること（すべて未確認）

順序は、ルーチンを更新する → Genie を一時停止して設定する → オーナーが自分の 🐦 で試す → 家族に知らせる → オーナーの OK のあとで家族1人が試す。dove は自分宛てでは動かないので、最初の試験から家族のグループを使います。各段階でオーナーの OK をもらいます。

1. iPhone から送った 🐦 のコードポイント（U+1F426 だけか、U+FE0F が付くか）。
2. オーナー本人（`is_from_me=true`）の 🐦 と、家族（`is_from_me=false`）の 🐦 の両方が POST されること。
3. 途中の 🐦、🐦‍🔥、🐦‍⬛、🐦 だけ、では POST されないこと。
4. `imsg send --text 🐦` で guid が返り、相手の端末で大きい絵文字に見えること。2通目が順に並ぶこと。
5. Genie が送った 🐦 と本文が watch に戻ったとき（VS16 の有無を含む）に、webhook が呼ばれないこと。ログに `ignored` の種類が出ることを見る。
6. 同じグループの 🪔 が、今までどおり GIF と本文で返ること（Job を使っていれば Job 経路のまま）。
7. ルーチンが `trigger` で dove と lamp を分け、伝書鳩の答えを返事 DB に1行で書き、同じ webhook を再送されても2行目を書かないこと。
8. 1分5件の枠が、家族の dove と lamp を合わせて足りること。
9. ログ、deadletter、ルーチンの記録に、ハンドル、本文、秘密、生のトーク GUID が無いこと。11章のとおり、既存の webhook ログと deadletter はメッセージ GUID を保持できます。値そのものは報告しない。
10. `imsg` が引用符、改行、`$()`、`--chat-id` に似た本文を、文字どおり送ること。

### 12.1 Mac mini に要る設定（値は書かない）

- `config.json`: `webhook_url`、`notion_data_source_id`、`group_chat_guids`（家族のグループを含める）、`dove_chat_guids`（家族のグループ）。任意で `sender_names`（呼び名）。`reply_marker` は 🐦 を含まない値か既定。`job_chat_ids` を使う場合も dove はそれを見ない。
- 設定ディレクトリ: `secret`（0600）、`notion-token`（0600）。
- 権限: フルディスクアクセス、Messages のオートメーション（今のまま）。

## 13. 実装するものと設計のみ

| 区分 | 項目 | 場所 |
|---|---|---|
| 実装 | `DoveSignal.scan`（先頭の飛ばし方は `Signal` と共有、ZWJ を除く、`request_text`） | `Signal.swift` |
| 実装 | `dove_chat_guids` の読み込み、整形、`config_unreadable` | `GenieConfig.swift` |
| 実装 | 有効な dove のトークの計算（`group_chat_guids` と `resolved` との積）、`dove_chat_not_in_groups` | `Engine.swift`（`ConfigGroupAuthorization` を使う） |
| 実装 | 判定の順序、`ignoredEmptyDove` と `ignoredMissingDoveGUID` | `Engine.swift`、`EngineTypes.swift` |
| 実装 | `WebhookPayload.trigger` / `requestText`（通常経路だけ。Job は省く）、dove は通常経路に固定 | `Webhook.swift`、`Engine.swift` |
| 実装 | `MessageRoute.trigger` と `chat_guid_hash`（省略可） | `StateStore.swift` |
| 実装 | dove の1通目 `🐦`、本文の 🐦 の除去、dove のトークの確認、`HeldSend.origin` | `Engine.swift`、`ReplyComposer.swift` |
| 実装 | dove のトークへの lamp の本文の検査、外部依頼の `outbound_dove_body` | `Engine.swift` |
| 実装 | `reply_marker` で U+1F426 を無効にする | `GenieConfig.swift` |
| 実装 | テスト、変異16本、manifest | `Tests/GenieCoreTests`、`tools/mutants` |
| 実装 | 文書: SPEC.md、README.md、config.example.json、この文書、docs/outbound-send.md の追記 | — |
| 設計のみ | 受け口ルーチンと伝書鳩のプロンプト（7章） | Grok Bot 側。別の作業 |
| 設計のみ | メニューと snapshot に dove のトークを出す | — |
| 設計のみ | 返事 DB の `trigger` 列を読んで照合する | 作らない（route で足りる） |
| 設計のみ | 自分宛て・1対1の dove、dove 専用の URL と秘密、GIF の dove 印 | 作らない |
| 設計のみ | 配送結果を伝書鳩へ返す | 作らない |

## 14. GREEN 一覧

### 14.1 テストの作り方

- 本番と同じ入口を通します。受信は `GenieEngine.ingestWatchLine`、取得と送信は `GeniePoller.tick()`（保留の再開も同じ入口）、起動は保存した JSON から作り直した Engine です。テストだけの入口は作りません。
- 時間は `ManualClock`、順序は `Gate` と probe で決めます。sleep は使いません。
- 観測には `FakeWebhook`（ヘッダーの元になる冪等キーと、本文の JSON）、`FakeSender.outgoing`、`FileStateStore` の実 JSON（再起動・秘匿）、ログの記録を使います。
- 送信0回、POST 0回のテストには、条件を直せば送れる正の対照を同じテストに入れます。
- テストのメソッド名は `testDVnn` で始め、manifest の `filter` には1つのテスト名を書きます。
- 変異は、テストのアサーションで落ちたときだけ殺したと数えます（`tools/check-mutants.py` の `KILLED`）。コンパイルエラー、throw、クラッシュで落ちても数えません。変異はコンパイルが通るように書きます。

テスト表では、ファイルの略号と実際のメソッド名を並べます。

| 略号 | ファイル |
|---|---|
| D | `DoveTriggerTests.swift` |
| R | `DoveReplyTests.swift` |
| G | `GroupDocumentationTests.swift` |
| N | `NotionReplyTests.swift` |

架空の値: chat_id 7 は dove のトーク（`iMessage;+;chat000000000000000001`）、8 は設定のグループだが dove ではない（`…0002`）、42 はメニューだけで許可したトークです。

### 14.2 新規

| ID | 確認する動作 | テスト | 落とす変異 |
|---|---|---|---|
| DV01 | `dove_chat_guids` が無い・null なら空。前後に空白がある値、空の値、重複を含む設定でも、登録したグループで依頼を受け付ける。文字列でない要素があれば `config_unreadable` を記録し、直前の設定で受け付ける。`config.example.json` を読むと `[]` | `D.testDV01ConfigDefaultsAndInvalidReload`、`G.testExampleUsesEmptyGroupsAndDefaultReplyMarker` | なし |
| DV02 | `dove_chat_guids` が空なら、chat 7 の家族の 🐦 は `ignoredNoSignal` で POST 0回。同じトークの 🪔 は `trigger:"lamp"` で POST される | `D.testDV02EmptyDoveConfigLeavesLampEnabled` | なし |
| DV03 | `dove_chat_guids` にあるが `group_chat_guids` に無いトーク（メニューでは許可済み）の 🐦 は POST 0回。`dove_chat_not_in_groups` は1回だけで、detail は `1`、ログに guid は無い。`group_chat_guids` に足すと POST される | `D.testDV03DoveNeedsGroupConfig` | なし |
| DV04 | chat 8、chat 42、1対1の 🐦 は `ignoredNoSignal` で POST 0回。chat 7 の 🐦 は POST 1回 | `D.testDV04DoveOnlyInDoveChats` | dv09 |
| DV05 | `おはよう🐦`、`今日は 🐦 だ`、`🐦‍🔥 x`、`🐦‍⬛ x` は POST 0回。`" \u{200B}🐦質問"` は POST 1回。編集・取り消し・リアクションと、自分宛てとして設定したトークでの他メンバーの依頼は無視する | `D.testDV05OnlyLeadingDoveTriggers`、`D.testDV05DoveHonorsMutationReactionAndForcedSelf` | dv01 |
| DV06 | `"🐦\u{FE0F}\u{3000} て\u{3099}す\n続き"` で `request_text == "です\n続き"`、`text` は NFC の全文 | `D.testDV06RequestTextStripsVariationSelectorAndSpaces` | dv02 |
| DV07 | dove の payload のキーの集合と値が 6.3 と一致する（`trigger:"dove"`、`request_text`、URL は `webhook_url`、Bearer は `secret`）。家族には通常経路の `sender_handle` があり、本人には無い | `D.testDV07DovePayloadExactKeys` | dv08 |
| DV08 | 通常経路の 🪔 は今のキー＋`trigger:"lamp"` だけで、`request_text` は無い。Job 経路の 🪔 は今のキーと同じで、`trigger` は無い | `D.testDV08LampPayloadOnlyAddsTriggerOnOrdinaryRoute` | dv06 |
| DV09 | chat 7 が `job_chat_ids` にあり Job URL が有効でも、🐦 は `webhook_url` と `secret` へ送られ、Job の秘密は読まれない。🪔 は Job へ行く。`webhook_url` が空なら dove は deadletter `webhook_not_configured`（kind `webhook`）で、Job は呼ばれない | `D.testDV09DoveIgnoresJobRoute` | dv12 |
| DV10 | dove の route の行を tick で取ると、`outgoing` は「文字 `🐦`（1スカラー）、本文」の2件だけ。GIF が使えても `sendFile` は0回で、独自の `reply_marker` は使わない | `R.testDV10DoveReplyIsTextBirdThenBody` | dv11 |
| DV11 | chat 7 の 🪔 の返事は `expectedGIFOutgoing` のとおり。GIF 失敗時には `reply_marker` の文字 | `R.testDV11LampReplyInDoveChatKeepsGIF`、`GifMarkerTests.testImageFailedFallsBackToConfiguredMarker` | dv07 |
| DV12 | dove の route に対して、行の `chat_id` が 42（許可あり）なら送信0回で `reply_chat_mismatch`。`chat_id` が無い行は chat 7 にだけ送る。Notion の実デコードで欠落・一致・別トーク・不正数値を確認する | `R.testDV12DoveReplyNeverLeavesItsChat` | dv05 |
| DV13 | 取り込んだあと `dove_chat_guids` から外すと（`group_chat_guids` には残す）、`reply_dove_chat_disabled` で送信0回。ロック確認後または1通目の後に外すと、次の送信を止める。一覧で非グループと確定した返信は終端にし、グループに戻っても送り直さない。一覧欠落からは照合回復後に再開し、DB 交換では古い route を使わない。GIF に切り替えて送ることもない | `R.testDV13DoveReplyHoldsForMissingListAndResumes`、`R.testDV13NonGroupDoveReplyIsTerminal`、`R.testDV13DoveRevocationStopsBeforeMarkerOrBody`、`R.testDV13LockReturnRevocationAndDatabaseSwap`、`R.testDV13PersistedDoveRouteRejectsReusedChatIDWithoutKnownChat` | なし |
| DV14 | DV10 のあと、1通目の guid で `🐦`（`is_from_me=true`）を ingest すると `ignoredSentGUID`（種類まで一致）で POST 0回。本文の echo も `ignoredSentGUID` | `R.testDV14OwnMarkerEchoStopsAtSentGUID` | dv03 |
| DV15 | 新しい guid、指紋の窓より後（300秒後）に、`"🐦\u{FE0F}"` を本人からと家族から ingest すると、どちらも `ignoredEmptyDove` で POST 0回 | `D.testDV15EmptyDoveEchoNeverPosts` | dv04 |
| DV16 | 行の本文が `"🐦 🧞‍♂️ 答え"` なら2通目は `"答え"`、呼び名があれば `"{name}へ：答え"`。`"🐦"` だけなら `reply_empty_body`、`"🐦 🪔 x"` なら `reply_still_matches_signal` で、どちらも送信0回 | `R.testDV16DoveBodyAndAddressee` | なし |
| DV17 | chat 7 への 🪔 の返事で、本文が `"🐦 x"` なら送信0回で `reply_still_matches_dove`。同じ本文でも chat 42 なら今までどおり送られる。保留中と1通目の直後に dove を有効にしたケースも確認する。印または本文の送信意図を保存したときに許可を外すと、その部の送信を止めて `reply_chat_disabled` を記録する | `R.testDV17LampBodyStartingWithDoveIsDroppedInDoveChat`、`R.testDV17LampBodyRechecksAfterHoldAndMarker`、`R.testDV17LampRechecksPermissionAfterSavingSendIntent` | dv13、dv17 |
| DV18 | Engine A で dove を取り込み保存したあと、保存した JSON から作った Engine B の tick で `["🐦", 本文]` を送る。1通目のあとで作り直した場合は本文だけを送る。印・本文の送信途中、保存失敗での再開回数と、旧 JSON の GIF 返信も確認する | `R.testDV18DoveTriggerSurvivesRestart`、`R.testDV18DoveResumesBodyAndLegacyRouteUsesGIF`、`R.testDV18InterruptedMarkerAndBodyRecoverFromJSON` | dv14 |
| DV19 | `reply_marker` が `"🐦"` や `"🕊️🐦"` なら既定に戻り、`reply_marker_invalid` は1回だけ。`"🕊️"` は有効。有効な値を挟んで再び無効になると、警告をもう1回出す | `D.testDV19BirdMarkerWarningRearms` | なし |
| DV20 | 外部依頼の family が chat 7 のとき、本文 `"🐦 お知らせ"` は `outbound_dove_body` で終端になり、送信0回。同じページを再取得しても送信0回。整形後の本文、保留中と1通目の直後の有効化も確認する。正の対照は通常の通知 | `R.testDV20OutboundRawAndFinalBirdBodiesTerminate`、`R.testDV20OutboundRechecksAfterHoldAndMarker` | dv15 |
| DV21 | 一時停止中の 🐦 は `deferredPaused` でカーソルが進まず、解除後に POST される。503 の再送のあいだに dove から外すと、`webhook_chat_disabled`（detail `dove`）で止まる。503 後の再送と、受理後にカーソルを保存できず再起動した場合は、ヘッダーと JSON の冪等キーを維持する。DB 交換後に最終 POST が例外で戻った場合は、新 DB のカーソルを維持する | `D.testDV21DatabaseSwapDiscardsFinalWebhookException`、`D.testDV21PausedAndRetryRecheck`、`D.testDV21RetryAfter503ReusesWebhookKeys`、`D.testDV21RestartBeforeFinishSaveReusesWebhookKeys` | dv16 |
| DV22 | ログ、deadletter、state の JSON にハンドル、本文、`request_text`、webhook の秘密が出ない。生のトーク GUID は `known_chats` に限り、dove の route には照合用のハッシュを保存する。既存の webhook ログと deadletter はメッセージ GUID を保持できる。印と本文の `reply_sent` に送信結果の GUID が出ない。route は dove にだけ `"trigger":"dove"` を保存する。route を保存できなければ POST しない | `D.testDV22RouteSaveFailurePreventsPost`、`R.testDV22DoveValuesStayOutOfPersistentOutputs` | なし |
| DV23 | dove の本文が `.uncertain` ならちょうど1回だけ送り直す。同じトークで lamp 3件と dove 3件を送ると、既定の1分5件で6件目が止まる | `R.testDV23LampAndDoveShareRateWindow`、`R.testDV23DoveBodyResendsOnce` | なし |
| DV24 | SPEC.md の4.13節に `dove_chat_guids`、`trigger`、Job 経路には `trigger` を付けないことが書かれている。README の dove 節に Genie 側の実装とモックテスト、受け口ルーチンの未更新、実機未確認の3区分と本書へのリンクがある。config.example.json の配列は空。追跡しているファイルの検査（個人の識別子）を通る | `G.testDV24DoveDocumentationAndExampleAgree`、`N.testPersonalIdentifiersStayOutOfDocsAndTests` | なし |

変異欄の「なし」は、その行に専用の変異がないことを示します。新しい契約や完成条件を足すときは、壊し方も1つ足します（[LESSONS.md](../LESSONS.md)）。

### 14.3 回帰（基点でも通る。期待値の更新を含む）

| ID | GREEN when | 既存のテスト | 落とす変異（既存） |
|---|---|---|---|
| DV30 | 🪔 の判定は今のまま | `SignalTests`、`GroupConfigTests.testGC17MarkerValidationAndNFC` | `gc17-lamp-only-at-start` → `GroupConfigTests.testGC17MarkerValidationAndNFC` |
| DV31 | GIF の1通目と文字への切り替えは今のまま | `GifMarkerTests.testImageFailedFallsBackToMarkerAndContinues`、`GifMarkerTests.testImageFailedFallsBackToConfiguredMarker` | `gif-no-fallback` → `OutboundRecoveryTests.testOB15GIFFailureUsesCustomMarkerAndUnavailableImageSkipsLaunch`、`gif-default-marker` → `GifMarkerTests.testImageFailedFallsBackToConfiguredMarker` |
| DV32 | 2通の分け方と2通目の整形は今のまま | `SplitReplyTests.testTextFallbackSendsExactlyTheFourScalars`、`SplitReplyTests.testSecondMessageHasNoMarkerOrLeadingSpace` | `split1` → `SplitReplyTests.testTextFallbackSendsExactlyTheFourScalars`、`split2` → `SplitReplyTests.testSecondMessageHasNoMarkerOrLeadingSpace` |
| DV33 | Job の payload は変わらない。Job の選択は許可にならない | `JobRouteTests.testG02JobUsesItsURLSecretAndUnchangedPayload`、`JobRouteTests.testG04JobSelectionDoesNotGrantPermission` | `job2-ordinary-route` → `JobRouteTests.testG02JobUsesItsURLSecretAndUnchangedPayload`、`job4-bypass-allowlist` → `JobRouteTests.testG04JobSelectionDoesNotGrantPermission` |
| DV34 | 通常経路の payload の数え方。期待するキーの数を1つ増やす（`trigger`）。メソッド名と manifest の `filter` は変えない | `GroupChatTests.testGC12NormalizedHandleAndUnknownHandleUseTenKeys` | `gc12-raw-handle` → `GroupChatTests.testGC12NormalizedHandleAndUnknownHandleUseTenKeys` |
| DV35 | 設定のグループの判定 | `GroupChatTests.testGC05RejectsUnresolvedNonGroupCaseAndInitialFailureWithPositiveControl` | `gc05-accept-direct` → `GroupChatTests.testGC05RejectsUnresolvedNonGroupCaseAndInitialFailureWithPositiveControl` |
| DV36 | 送った guid と指紋 | `EngineWatchTests.testGuidIdempotencyAndSentGuidAndFingerprint` | `gc21-ignore-sent-guid` → `EngineWatchTests.testGuidIdempotencyAndSentGuidAndFingerprint` |
| DV37 | 本文を1つの引数にする境界を確認する | `GroupTransportTests.testBodyIsOneLiteralArgumentAndEchoDoesNotInterpretIt` | `gc20-shell-command` → `GroupTransportTests.testBodyIsOneLiteralArgumentAndEchoDoesNotInterpretIt` |
| DV38 | payload の encode が route の記録より先にあることを静的に確認する | `GroupTransportTests.testPayloadEncodingFailurePrecedesRouteRecording` | `fix1-payload-after-route` → `GroupTransportTests.testPayloadEncodingFailurePrecedesRouteRecording` |
| DV39 | ハンドルがログに漏れない | `GroupPrivacyRegressionTests.testGC15NoHandleBodyMarkerOrConfigTableLeaksAcrossDeliveryFailureAndReply` | `gc15-handle-log` → `GroupPrivacyRegressionTests.testGC15NoHandleBodyMarkerOrConfigTableLeaksAcrossDeliveryFailureAndReply` |
| DV40 | 外部依頼の echo と本文の検査 | `OutboundSendTests.testOB19OutboundEchoesNeverPostWebhook`、`OutboundPrivacyTests.testOB23BodyValidation` | `ob19-skip-sent-guid` → `OutboundSendTests.testOB19OutboundEchoesNeverPostWebhook`、`ob23-skip-body-validation` → `OutboundPrivacyTests.testOB23BodyValidation` |
| DV41 | 例の設定。`dove_chat_guids: []` を足した期待値に直す | `GroupDocumentationTests.testExampleUsesEmptyGroupsAndDefaultReplyMarker` | `gc03-example-omits-new-keys` → `GroupDocumentationTests.testExampleUsesEmptyGroupsAndDefaultReplyMarker` |
| DV42 | 目印の設定 | `GroupMarkerTests.testGC16ConfiguredMarkerIsNormalizedButLegacyMarkerDoesNotReplaceIt` | `gc16-ignore-configured-marker` → `GroupMarkerTests.testGC16ConfiguredMarkerIsNormalizedButLegacyMarkerDoesNotReplaceIt` |

通常経路の payload のキーを数えたり、完全に比べたりしている既存テストは、`trigger:"lamp"` を足した期待値に直します。直したテストは PR の本文に並べます。期待値を直したあとも、既存の変異がすべて `KILLED` であることを確かめます。

### 14.4 新しい変異（16本）

仕様案では `dv10` を、`group_chat_guids` に無くても `dove_chat_guids` だけで受信できる変異に割り当てていました。`dv09` は `isDoveChat` を迂回するため、グループ設定との照合も外します。DV03 は `testDV03DoveNeedsGroupConfig` で直接確認し、専用の `dv10` は欠番です。

| name | 壊し方 | filter |
|---|---|---|
| dv01-any-position | `DoveSignal` を「どこかに U+1F426 を含む」にする | `DoveTriggerTests.testDV05OnlyLeadingDoveTriggers` |
| dv02-keep-fe0f | 🐦 の後の U+FE0F と空白を `request_text` から外さない | `DoveTriggerTests.testDV06RequestTextStripsVariationSelectorAndSpaces` |
| dv03-own-dove-posts | 🐦 の echo が送信済み GUID・指紋・空依頼の判定を通過する | `DoveReplyTests.testDV14OwnMarkerEchoStopsAtSentGUID` |
| dv04-accept-empty-dove | 空の `request_text` を拾う | `DoveTriggerTests.testDV15EmptyDoveEchoNeverPosts` |
| dv05-dove-row-chat | dove のとき行の `chat_id` を送り先にし、食い違いでも捨てない | `DoveReplyTests.testDV12DoveReplyNeverLeavesItsChat` |
| dv06-job-lamp-trigger | Job 経路の 🪔 にも `trigger:"lamp"` を付ける | `DoveTriggerTests.testDV08LampPayloadOnlyAddsTriggerOnOrdinaryRoute` |
| dv07-marker-by-chat | 印を route の trigger ではなくトークで決める（dove のトークでは 🪔 の返事も 🐦） | `DoveReplyTests.testDV11LampReplyInDoveChatKeepsGIF` |
| dv08-dove-no-trigger | dove の payload に `trigger` を入れない | `DoveTriggerTests.testDV07DovePayloadExactKeys` |
| dv09-dove-any-allowed-chat | dove のトークかを見ず、受信の許可だけで拾う | `DoveTriggerTests.testDV04DoveOnlyInDoveChats` |
| dv11-dove-uses-gif | dove の1通目を今の GIF / `reply_marker` にする | `DoveReplyTests.testDV10DoveReplyIsTextBirdThenBody` |
| dv12-dove-job-route | dove を `job_chat_ids` の Job 経路へ送る | `DoveTriggerTests.testDV09DoveIgnoresJobRoute` |
| dv13-lamp-body-dove | dove のトークへの 🪔 の返事で、🐦 で始まる本文を送る | `DoveReplyTests.testDV17LampBodyStartingWithDoveIsDroppedInDoveChat` |
| dv14-route-trigger-dropped | route を保存するときに `trigger` を省く | `DoveReplyTests.testDV18DoveTriggerSurvivesRestart` |
| dv15-outbound-skip-dove-recheck | 保留や印のあとに有効になった dove の宛先へ本文を送る | `DoveReplyTests.testDV20OutboundRechecksAfterHoldAndMarker` |
| dv16-webhook-exception-ignores-db-reset | DB 交換後に最終 POST が例外で戻っても旧行を保存する | `DoveTriggerTests.testDV21DatabaseSwapDiscardsFinalWebhookException` |
| dv17-lamp-stale-send-permission | 🪔 の返事の送信直前に設定を再読込しても、許可と GUID を再読込前の設定で照合する | `DoveReplyTests.testDV17LampRechecksPermissionAfterSavingSendIntent` |

完了の条件

- `swift test` が全部通る。
- `python3 tools/check-mutants.py --probes` のあと `python3 tools/check-mutants.py` を実行し、既存と追加した変異がすべて `KILLED` になる。
- `scripts/check-tracked-text.py` が何も報告しない。
- Linux の CI が通る。macOS の CI と実機は別に確かめ、確かめるまでは未確認と書く。

## 15. 関連文書への反映

- `SPEC.md` の2章、4.2、4.4、4.5、4.9、4.13、決定26、9章。
- `README.md` の「家族のグループで 🐦（伝書鳩）を呼ぶ」。
- `config.example.json` の `dove_chat_guids`。
- `docs/outbound-send.md` の5.3と11章。

## 16. 関連資料

- SPEC.md 4.2、4.4、4.5、4.11、4.12、5.1
- docs/gif-marker.md（1通目の契約）、docs/outbound-send.md（外部依頼）
- docs/design.md は初期の 🐦 トーク向けの案です。そこで保留していた ZWJ 絵文字（🐦‍⬛、🐦‍🔥）は、この仕様で「合図にしない」と決めました。今の方針は SPEC.md とこの文書が正です。

## 17. 残り

- 既存の問題として、DB 交換後に旧 watch の後続行でカーソルが進むことがあります。lamp 経路でも同じ挙動です。
