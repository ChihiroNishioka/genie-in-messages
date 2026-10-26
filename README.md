# genie-in-messages 🧞

iMessageの中に常駐する、アンビエント型のアシスタントbot「ジーニー」（ランプの魔人🧞）。

自分のApple IDから合図付きのメッセージを送ると、Mac上の常駐メニューバーアプリがそれを拾ってGrok Botに渡し、返事を同じトークにiMessageで返す。わざわざ別のアプリを開かなくても、いつものトークの中から呼び出せるのがコンセプト。

## ステータス

中心処理とメニューバーアプリの最初の版を実装済み。実機での送信・chat.db の読み取り・許可ダイアログの確認はまだ行っていない。仕様の正は `SPEC.md`（実機確認と Notion の置き場所を含む）。

## 動かし方

```bash
swift test
swift build --product GenieMenuBar   # macOS
scripts/assemble-app.sh --identity "$GENIE_CODESIGN_IDENTITY"
```

署名IDは Apple Development 証明書の名前を引数か `GENIE_CODESIGN_IDENTITY` で渡す。アドホック署名は使わない。証明書はリポジトリに置かない。

設定ディレクトリは `~/.config/genie-in-messages/`（0700）。`config.json` の例は [`config.example.json`](config.example.json)。webhook のトークンは `secret`（0600）に置き、送信のたびに読み直す。返事の取得用トークンは任意の `reply-secret`（0600）。どちらもコードに書かない。

`imsg` は既定で `/opt/homebrew/opt/imsg/libexec/imsg` を直接起動する。パスは設定で変えられる。`/opt/homebrew/bin/imsg`（bash ラッパー）は使わない。

メニューには状態、一時停止、トークごとの許可（初期はすべてオフ）、最後のエラー、ログを開く、ログイン時起動、画面ロック中の警告が出る。同じ Apple ID のほかの Mac では動かさない。

## 最初の起動

1. `scripts/assemble-app.sh --identity "$GENIE_CODESIGN_IDENTITY"` で `.app` を作る。署名IDは Apple Development 証明書。
2. その `.app` にフルディスクアクセスを付ける。子の imsg はその許可で `chat.db` を読む見込み（実機確認はまだ）。
3. メニューの「ログイン時に起動」をオンにする。再起動後に動かすには、システムの自動ログインも別途オンにする。
4. 初回の送信で、Messages を操作してよいかの許可ダイアログが出る。Grok Bot 側で許可済みでも、このアプリからは別の許可になる。
5. 同じ Apple ID のほかの Mac では動かさない。
6. トークの許可は初期状態ですべてオフ。オンにしたトークだけ転送する。
7. Notion で内部連携を作り、このデータベースだけをその連携に共有する。データベース `875a3b9a-fa64-4631-88cf-1328c2bef05f`、データソース `1a7710fa-96a4-4fb3-9fa7-8c7eb2337513`。データソース ID を `config.json` の `notion_data_source_id` に書く。トークンはメニューの「Notion トークンを設定」から入れる。ファイルは `~/.config/genie-in-messages/notion-token`（0600）で、画面には出さない。

## 返事の取得

置き場所は Notion のデータベース（2026-10-26 決定）。ボットが返事 1 件につき 1 行を足し、Mac はデータソースを約 10 秒ごとに query する。`notion_data_source_id` が空のときは、差し替え用の GET JSON（`reply_fetch_url`）に戻る。どちらも https だけを使い、トークンは使うたびに読み直す。

Notion の列は `reply_id`（title）、`chat_id`（number、確認用）、`in_reply_to_guid`（rich_text、必須）、`idempotency_key`（rich_text）、`text`（rich_text）、`created_at`（created_time）。どこまで読んだかは水位（読み終えた行の最も新しい時刻）で、次の取得はその 120 秒前から読み直す。ただし読み始めた分より前には戻らない。重複は処理済み ID で落とす。処理済みの行と、保留中・送信中の返事は `reply_page_limit`（既定 100）件の枠に数えない。カーソルが空のときは、その取得を始めた分の先頭から読む。処理済みでない返事より先には水位を進めない。読み直す範囲は 2000 行まで（処理済みの行と保留中の行を含む）。`Notion-Version` は `2026-03-11`。平均で毎秒 3 回を超えないよう間隔を空け、429 と 529 は `Retry-After` を待つ。ボット側の約束（1行は列を揃えて一度に書く、7日より古い行を片付ける、など）は `SPEC.md` 5.1。

送り先は、webhook に渡したときの guid と chat_id の対応から決める。`reply_id` で冪等にする。必須の列が欠けた行、対応が無い行、取得元の chat_id と食い違う行は送らない。本文はログに出さない。

GET JSON を使う場合の形は `{ "v": 1, "cursor", "replies": [{ "id", "chat_id", "in_reply_to_guid", "text", "created_at" }] }`。`in_reply_to_guid` と `created_at` は必須。`reply-secret`（0600）があれば Bearer を付ける。cursor は、そのページの id 付き返事を処理し終えるまで進めない。1ページは 100 件までを想定し、壊れた要素は飛ばしてログに残す。

## 送信

`imsg` 0.19.1 の `send` は本文を `--text` でしか受けない。標準入力も本文ファイルはなく、`--file` は添付用なので、本文は `ps` の引数に出る。`imsg rpc` の標準入力なら引数には出ないが、実機で未確認の別経路なので使っていない。`send` と `chats` には期限を付ける（既定 150 秒と 30 秒）。期限を超えた送信は結果不明として再送しない。

webhook は `Authorization: Bearer`。重複排除用の `idempotency_key`（メッセージの guid）は本文 JSON に入れる。`Idempotency-Key` ヘッダはボットに届かない。

画面ロックは「ロック / 解除 / 不明」の3つ。CoreGraphics を直接呼び、ロックと解除の通知も見る。不明のときは送信を試し、`-1712`（`not_started`）なら保留する。

## ファイル

- [`SPEC.md`](SPEC.md): 仕様書（引き継ぎ用）。決定済み要件、アーキテクチャ、決定事項をまとめたもの。
- [`docs/design.md`](docs/design.md): 詳細設計案。初期の検討資料で、LaunchAgentとSwiftの小さなブリッジで🐦トークを中継する案として書かれている。現在の方針（メニューバーアプリ）は `SPEC.md` が正。

## 経緯

旧仮名は `imsg-grok-bridge`。このリポジトリを作るときに `genie-in-messages` に改名した。

## 決定事項（2026-10-26）

- 呼び出しの合図: 🪔（U+1FA94。直後の U+FE0F はあってもなくても可）。🧞🧞‍♀️🧞‍♂️ は呼び出しに使わない。旧案の🤖は廃止。
- 返事の経路: B案。ボットが返事を決まった場所に書き、アプリが取りに行って検査してから送る。置き場所は Notion。
- 返事していいトーク: 許可リスト制。トークごとにオン・オフで、初期状態は全部オフ。
- 返信の印: 既定は先頭の「🧞‍♂️」で、設定で変えられる。空、空白だけ、🪔 で始まる印は、製品既定の 🧞‍♂️ に戻し、警告をログに1行出す。
- 署名: Apple Development 証明書（署名用の証明書だけ Keychain）。
- ボットの役割: 何でも答える汎用アシスタント（Grok Bot の webhook ルーチン）。
- 動かすMacは同じApple IDにつき1台だけ。ちひろ専用の値はコードに書かず、すべて設定から読む。

詳しくは `SPEC.md` 7章。
