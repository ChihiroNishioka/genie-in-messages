# genie-in-messages 🧞

iMessageの中に常駐する、アンビエント型のアシスタントbot「ジーニー」（ランプの魔人🧞）。

自分のApple IDから合図付きのメッセージを送ると、Mac上の常駐メニューバーアプリがそれを拾ってGrok Botに渡し、返事を同じトークにiMessageで返す。許可したトークでは、自分も他のメンバーも同じ合図で呼べる。わざわざ別のアプリを開かなくても、いつものトークの中から呼び出せるのがコンセプト。

## ステータス

中心処理とメニューバーアプリの最初の版を実装済み。実機での送信・chat.db の読み取り・許可ダイアログの確認はまだ行っていない。仕様の正は `SPEC.md`（実機確認と Notion の置き場所を含む）。

## 動かし方

```bash
swift test
python3 tools/check-mutants.py       # 壊し方。テストが通ったら失敗
swift build --product GenieMenuBar   # macOS
scripts/assemble-app.sh --identity "$GENIE_CODESIGN_IDENTITY"
```

署名IDは Apple Development 証明書の名前を引数か `GENIE_CODESIGN_IDENTITY` で渡す。アドホック署名は使わない。証明書はリポジトリに置かない。

設定ディレクトリは `~/.config/genie-in-messages/`（0700）。`config.json` の例は [`config.example.json`](config.example.json)。webhook のトークンは `secret`（0600）に置き、送信のたびに読み直す。Job Engine 用のトークンは別の `job-secret`（0600）。返事の取得用トークンは `reply-secret`（0600）。一般の GET JSON では任意だが、Job Engine では必須。秘密はコードに書かない。

一時停止中に設定を変えたら、許可ウィンドウの「一覧を更新」を押して表示を確認します。一時停止中は「一覧を更新」と snapshot のときにも設定を読み直します。受信・送信・再試行・返信のポーリングは再開しません。

誰が呼べるかは、メニューのチャット許可と、設定で許可したグループの和。オンのトークにいる人は全員。オフは自分の 🪔 も無視する。自分宛てトークは、グループでなく participant が1人で自分のハンドルと一致するときだけ、受信側の重複を無視する。表示名の表は任意で、反応には影響しない。`self_chat_ids` も任意で、書いた `chat_id` を自分宛てとして扱う。番号とメールは架空の例。

```json
{
  "self_sender_name": "me",
  "sender_names": {
    "+1 555 010 0000": "family",
    "family@example.com": "family-mail"
  },
  "self_chat_ids": [7]
}
```

`+1 555 010 0000` と `+15550100000` は区切りを除くと同じキーになり、同じ表示名を引く。メールは大文字と小文字を区別しない。表が無いときは、連絡先名が watch に既にあればそれを使う。その名前がメールまたは電話番号の形なら、`sender` が空でも空にする。無ければ空。自分の表示名の既定は `me`。規則は `SPEC.md` の 4.10。webhook には `sender_is_me` と `sender_name` を足す。`v` は 1 のまま。ハンドルは通常は送らない。設定で許可したグループの例外は次の節を参照。

`job_chat_ids` に指定したトークが許可リストでもオンなら、その 🪔 を `job_webhook_url` に送る。ほかのトークは従来の `webhook_url` と `secret` を使う。送り先はメッセージごとに一度決め、再送中に設定が変わっても切り替えない。基本は JSON の9キーで、設定のグループの家族に使えるハンドルがあれば10キーです。`v: 1` と重複排除の契約は同じです。

```json
{
  "job_webhook_url": "http://127.0.0.1:3321/ingress/genie",
  "job_chat_ids": [7]
}
```

Job Engine を使うときは、`job-secret` と `reply-secret` に Job Engine の `GENIE_TOKEN` と同じ値を入れる。別のファイルだが、値は同じにする。Job Engine の返信取得では `reply-secret` が必須で、無いと 401 になる。

Job Engine 側の `GENIE_ALLOWED_CHAT_IDS` と `ALLOWED_SOURCE_CHAT_IDS` に同じ `chat_id` を入れる。どちらかの許可に無いと `webhook_http_403` で再送せずに止まり、deadletter の kind は `job_webhook` になる。

`job-secret` は自動では作られない。送信のたびに読み直し、欠落、空、0600以外なら送らず deadletter に残す。読めないときはバックオフして再試行する。通常の `secret` へは切り替えない。Job の deadletter は `kind: "job_webhook"` で、本文と秘密を残さない。

`job_webhook_url` が空なら、指定したトークも通常の `webhook_url` に送る。空でないが使えない URL なら `url_not_https` で止める。メニューにもこの区別を出す。通常の `webhook_url` は https のみ。Job と `reply_fetch_url` は https に加え、host が `127.0.0.1`、`::1`、`localhost` の http だけを許す。例では名前解決の差を避けるため `127.0.0.1` を使う。実機での確認が残る項目は SPEC の [実機で未確認のこと](SPEC.md#9-実機で未確認のこと) にまとめる。

`imsg` は既定で `/opt/homebrew/opt/imsg/libexec/imsg` を直接起動する。パスは設定で変えられる。`/opt/homebrew/bin/imsg`（bash ラッパー）は使わない。

メニューバーの印は金色のランプと、注ぎ口の上に立つ雲（通常・一時停止・要対応。高さ 18pt いっぱい、色のまま。`scripts/make-menu-icon.py` が背景と周りの紫を抜く）。Finder のアイコンは `scripts/make-app-icon.py` が `AppBundle/GenieLampV2-1024.png` を角丸の内側に縮小して作る。メニューには状態、一時停止、トークごとの許可（検索できるウィンドウ。初期はすべてオフ。オンを上に表示。一覧に無いオンのトークも先頭に出す）、最後のエラー、ログを開く、ログイン時起動、画面ロック中の警告が出る。watch が終わった理由はログに残す。標準エラーは最後の空でない1行だけにし、決まったエラーの語以外は出さない。本文・電話番号・宛先は出さない。同じ Apple ID のほかの Mac では動かさない。

メニューの「最後のエラー」は、送信などのエラーと返信取得の障害を別々に保持する。両方あるときは「最後のエラー: 送信など: …」と「返信の取得: …」の2行に出し、片方だけなら従来どおり「最後のエラー: …」の1行に出す。取得が回復しても送信などのエラーは残り、送信に成功しても続いている取得障害は消えない。`watch_start_failed` は取得障害中もメニューに出て、ランプが要対応になる。取得障害だけではランプの状態は変わらない。

## 家族のグループで使う

`config.json` の `group_chat_guids` にトークの guid を書きます。下はすべてダミーです。家族の電話番号やメールを設定する必要はありません。目印は自分宛ても含めて `reply_marker` で変えられます。

```json
{
  "group_chat_guids": ["iMessage;+;chat000000000000000001"],
  "reply_marker": "🕊️"
}
```

設定ファイルは `chmod 600 ~/.config/genie-in-messages/config.json` にします。メニューの許可と設定の許可は和です。一覧の guid と一致し、グループと確認できたものだけを設定から許可します。設定の行は「グループ（設定）」と表示され、メニューではオフにできません。macOS の表示とクリック無効は実機未確認です。

一時的に止めるときは、メニューで全体を一時停止します。一時停止中の 🪔 は、解除したあとに処理されます。対象のグループの許可を外すときは、次の順で操作します。

1. `group_chat_guids` から対象の guid を消します。
2. メニューでも許可していた場合は、設定から消したあとにメニューのスイッチをオフにします。設定から消すと行のロックが外れます。

通常の webhook には、設定で許可したグループの他メンバーからの合図だけに `sender_handle` を付けます。他メンバーの sender の形と、受け側が未知のキーを受け付けるかは実機未確認です。正規化したハンドルで、例えば `tel:+15550100000` や `email:family@example.com`。自分、自分宛て、1対1、メニューだけのグループには付けません。ログ、state、deadletter、allowlist、snapshot、メニューにはハンドルを残しません。設定の guid もログとメニューへ出しません。

`reply_marker` は、先頭の書記素が絵文字のときだけ有効です。先頭が Emoji_Presentation の絵文字、または U+FE0F（VS16）付きの絵文字である必要があります。`A`、`あ`、`#`、VS16 のない `🕊` は無効で、`🕊️` は有効です。無効な値は既定の 🧞‍♂️ に戻し、値を出さず `reply_marker_invalid` をログに記録します。ほかの長さや不可視文字の制約は SPEC の 4.9 を参照してください。

Job 経路でも、設定で照合済みのグループの家族に、契約に合う `sender_handle` を付けます。正規化後に ASCII の1〜256字で、電話は `tel:` と任意の `+` と1〜20桁、メールは小文字のローカル部1〜64字とドット付きドメインの契約に合うかを検証します。正確な正規表現は SPEC 4.5 を参照してください。合わなければキーを省き、実際の送信試行ごとに値を含まない info `job_sender_handle_unusable` を記録します。自分、自分宛て、1対1、メニューだけのグループには付けない規則です。`job_webhook_url` が空なら通常経路に戻り、正規化できなければ従来どおり空文字を付けます。

Job で家族の依頼を受け付ける場合、Job Engine の `GENIE_GROUP_CHAT_IDS` の既定は無効（空）。家族もジョブを作れるようになる。**member のジョブはオーナーの道具と権限で動く。`GENIE_GROUP_CHAT_IDS` を設定する前に、Routine 側で member に許す操作を決めること。** オーナーによる方針確認と家族への周知を、有効化の前提とする。

Job Engine を先に更新する。DB をバックアップし、v3 への移行と既存の動作を確認してから Genie を更新する。次に Job Engine の `GENIE_ALLOWED_CHAT_IDS`、`ALLOWED_SOURCE_CHAT_IDS`、`GENIE_GROUP_CHAT_IDS` の3つに対象 chat_id を設定して再起動する。その後で Genie の `job_chat_ids` に足す。順序を逆にすると403、旧 Job Engine に送ると未知キーで400となり、再送せず `job_webhook` の deadletter にする。旧版へ戻すには DB のバックアップが必要で、v3 以降のジョブはバックアップに戻すと失われる。

対象グループの 🪔 は、自分のものも含めてすべて Job Engine に行き、通常 webhook には行かない。家族の管理コマンド（`/help`、`/status`、`/cancel`、`/retry`）は Job Engine で返信なしに無視される。メニューだけの許可ではハンドルが付かないため、家族の Job 依頼は無視される。使えないハンドルもキーが省かれ、Job Engine は `not_from_me` にする。自分のメッセージはキー無しで従来どおり受け付ける。

`job_chat_ids` から外すと、新しい 🪔 は通常 webhook に進みます。通常経路の `sender_handle` の規則を使い、正規化できなければ空文字を送ります。再試行中のメッセージは初回に選んだ経路のままです。家族の新しい受付を止めるには Job Engine の `GENIE_GROUP_CHAT_IDS` を空にして再起動します。家族の 🪔 は Job Engine で 200 `not_from_me` になり、Genie は `webhook_delivered` と記録します。作成済みのジョブはオーナーが元のグループで `/cancel` します。claimed のジョブは `/cancel` で `cancel_requested` が立つだけで、すぐには止まりません。

### Job の家族利用で実機未確認のこと

Job の家族利用は実機未確認です。Mac mini で家族の 🪔 から受付2通、Worker の claim、完了2通までを確かめてください。家族の端末の sender が契約に合うか、オーナーの `/status` と `/cancel`、家族の管理コマンドが返信なしで無視されるかも確かめてください。

Job Engine の DB は `jobs.sender_handle` にハンドルを保存します。Worker CLI の claim、get、complete、fail は標準出力に `sender_handle` の値を出します。Routine は値を結果や通知に書き写しません。Routine の会話記録に値が残らないことと、Genie のログ、Job Engine サーバーの標準出力、launchd、deadletter に値が出ないことは実機未確認です。値そのものは報告しないでください。


実機では、オーナーが先に自分宛てで目印を試し、一時停止したままグループの guid を調べ、設定と表示を確認します。調べた guid を Issue、PR、チャットへ貼りません。グループの初回送信は家族に知らせ、オーナーの OK のあとに行います。読み取り手順と注意点は [SPEC.md の 4.11](SPEC.md#411-設定で許可するグループ)、残る確認は [実機で未確認のこと](SPEC.md#9-実機で未確認のこと) を参照してください。

## 最初の起動

1. `scripts/assemble-app.sh --identity "$GENIE_CODESIGN_IDENTITY"` で `.app` を作る。署名IDは Apple Development 証明書。
2. その `.app` にフルディスクアクセスを付ける。子の imsg はその許可で `chat.db` を読む見込み（実機確認はまだ）。
3. メニューの「ログイン時に起動」をオンにする。再起動後に動かすには、システムの自動ログインも別途オンにする。
4. 初回の送信で、Messages を操作してよいかの許可ダイアログが出る。Grok Bot 側で許可済みでも、このアプリからは別の許可になる。
5. 同じ Apple ID のほかの Mac では動かさない。
6. トークの許可は初期状態ですべてオフ。検索できるウィンドウで、オンにしたトークだけ転送する。
7. Notion で内部連携を作り、このデータベースだけをその連携に共有する。ID の例はダミー（データベース `00000000-0000-4000-8000-000000000001`、データソース `00000000-0000-4000-8000-000000000002`）なので、自分の ID を `config.json` の `notion_data_source_id` に書く。トークンはメニューの「Notion トークンを設定」から入れる。ファイルは `~/.config/genie-in-messages/notion-token`（0600）で、画面には出さない。

## 返事の取得

置き場所は Notion のデータベース（2026-10-26 決定）。ボットが返事 1 件につき 1 行を足し、Mac はデータソースを約 10 秒ごとに query する。`notion_data_source_id` が空なら GET JSON（`reply_fetch_url`）だけを使う。両方が設定されていれば、1回の取得で HTTP、Notion の順に両方を取る。HTTP が失敗しても Notion を取り、Notion が失敗しても先に保存した HTTP の結果を保つ。トークンは使うたびに読み直す。

Notion の列は `reply_id`（title）、`chat_id`（number、確認用）、`in_reply_to_guid`（rich_text、必須）、`idempotency_key`（rich_text）、`text`（rich_text）、`created_at`（created_time）。どこまで読んだかは水位（読み終えた行の最も新しい時刻）で、次の取得はその 120 秒前から読み直す。ただし読み始めた分より前には戻らない。重複は処理済み ID で落とす。処理済みの行と、保留中・送信中の返事は `reply_page_limit`（既定 100）件の枠に数えない。カーソルが空のときは、その取得を始めた分の先頭から読む。処理済みでない返事より先には水位を進めない。読み直す範囲は 2000 行まで（処理済みの行と保留中の行を含む）。`Notion-Version` は `2026-03-11`。平均で毎秒 3 回を超えないよう間隔を空け、429 と 529 は `Retry-After` を待つ。ボット側の約束（1行は列を揃えて一度に書く、7日より古い行を片付ける、など）は `SPEC.md` 5.1。

送り先は、webhook に渡したときの guid と chat_id の対応から決める。`reply_id` で冪等にする。必須の列が欠けた行、対応が無い行、取得元の chat_id と食い違う行は送らない。本文はログに出さない。

GET JSON を使う場合の形は `{ "v": 1, "cursor", "replies": [{ "id", "chat_id", "in_reply_to_guid", "text", "created_at" }] }`。`in_reply_to_guid` と `created_at` は必須。一般の GET JSON では `reply-secret`（0600）があれば Bearer を付ける。Job Engine では必須。cursor は、そのページの id 付き返事を処理し終えるまで進めない。1ページは 100 件までを想定し、壊れた要素は飛ばしてログに残す。

両方から取るときは HTTP の cursor を `http_reply_cursor`、Notion の cursor を `reply_cursor` に保存する。HTTP は、そのページの id 付き返信がすべて処理済みになったときだけ進める。保留や送信中があれば進めない。処理済み ID は両方で共有し、取得元の ID は衝突しない前提。HTTP の cursor が止まったまま処理済み ID が5000件を超えると、捨てた ID の返信が再送されるおそれがある。

HTTP だけのときは従来の `reply_cursor` を使い、移さない。HTTP だけから両方へ切り替えても cursor は移さず、HTTP は `http_reply_cursor` が空なら読み直す。重複は処理済み ID で落とす。Notion を外して HTTP だけに戻すときは、`reply_cursor` が Notion 形式なら cursor 無しで問い合わせる。新しいキーが無い config と state も読める。古い版に戻すと `http_reply_cursor` は無視され、HTTP は `reply_cursor` から読み直す。

同じ `in_reply_to_guid` への「受付」と「完了」も、それぞれ印と本文の2通で送る。対応表は1件送ったあとも残る。返信が増えると既定の1分5件のレート制限にかかりやすいため、Job Engine 側で受付の返信を控える選択もできる。

cursor を進めるのは「Genie が処理した」という意味で、配達の確認ではない。送り先不明、期限切れ、chat_id 不一致、許可オフ、空本文、🪔 で始まる本文は、送らず処理済みにする。結果不明の送信や deadletter も、Job Engine へ結果を返す仕組みはない。

## 送信

`imsg` 0.19.1 の `send` は本文を `--text` でしか受けない。標準入力も本文ファイルはなく、`--file` は添付用なので、本文は `ps` の引数に出る。`imsg rpc` の標準入力なら引数には出ないが、実機で未確認の別経路なので使っていない。`send` と `chats` には期限を付ける（既定 150 秒と 30 秒）。期限を超えた送信は結果不明として再送しない。

webhook は `Authorization: Bearer`。重複排除用の `idempotency_key`（メッセージの guid）は本文 JSON に入れる。`Idempotency-Key` ヘッダはボットに届かない。

画面ロックは「ロック / 解除 / 不明」の3つ。CoreGraphics を直接呼び、ロックと解除の通知も見る。不明のときは送信を試し、`-1712`（`not_started`）なら保留する。

## Mutant テスト

`gc13-job-handle.patch` は、Job 経路で一律に付けない、という古い期待を置き換えるため廃止しました。代わりに `sh-job-*.patch` と `sh-doc-old.patch` で、付与条件、空文字の省略、契約検証、再試行、案内文を壊して検査します。壊し方の置き場所と、新しい条件に壊し方を足す方法は `LESSONS.md` に書いてあります。

## ファイル

- [`SPEC.md`](SPEC.md): 仕様書（引き継ぎ用）。決定済み要件、アーキテクチャ、決定事項をまとめたもの。
- [`docs/design.md`](docs/design.md): 詳細設計案。初期の検討資料で、LaunchAgentとSwiftの小さなブリッジで🐦トークを中継する案として書かれている。現在の方針（メニューバーアプリ）は `SPEC.md` が正。

## 経緯

旧仮名は `imsg-grok-bridge`。このリポジトリを作るときに `genie-in-messages` に改名した。

## 決定事項（2026-10-26）

- 呼び出しの合図: 🪔（U+1FA94。直後の U+FE0F はあってもなくても可）。🧞🧞‍♀️🧞‍♂️ は呼び出しに使わない。旧案の🤖は廃止。許可したトークでは、自分も他のメンバーも同じ合図で反応する。
- 返事の経路: B案。ボットが返事を決まった場所に書き、アプリが取りに行って検査してから送る。置き場所は Notion。
- 返事していいトーク: 許可リスト制。トークごとにオン・オフで、初期状態は全部オフ。
- 返信の印: 1通目は `reply_marker`（既定 🧞‍♂️）だけ、2通目は本文だけ。古い `marker` は読み飛ばす。設定の目印と既定の 🧞‍♂️ で始まる受信は無視する。詳しくは `SPEC.md` の 4.4、4.9、決定 22。
- 署名: Apple Development 証明書（署名用の証明書だけ Keychain）。
- ボットの役割: 何でも答える汎用アシスタント（Grok Bot の webhook ルーチン）。
- 動かすMacは同じApple IDにつき1台だけ。オーナー専用の値はコードに書かず、すべて設定から読む。

詳しくは `SPEC.md` 7章。
