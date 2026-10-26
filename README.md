# genie-in-messages 🧞

iMessageの中に常駐する、アンビエント型のアシスタントbot「ジーニー」（ランプの魔人🧞）。

自分のApple IDから合図付きのメッセージを送ると、Mac上の常駐メニューバーアプリがそれを拾ってGrok Botに渡し、返事を同じトークにiMessageで返す。わざわざ別のアプリを開かなくても、いつものトークの中から呼び出せるのがコンセプト。

## ステータス

中心処理とメニューバーアプリの最初の版を実装済み。実機での送信・chat.db の読み取り・許可ダイアログの確認はまだ行っていない。実装は、実機確認を反映した仕様（`spec/device-check-2026-10-26`、PR #3）に合わせてある。この実装は `SPEC.md` 自体は変更しない。

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

## 返事の取得

置き場所は未決定。`ReplySource` で差し替えられ、既定は設定した URL を 10 秒ごとに GET する。URL が空なら取得しない。http は使わず、https だけを受け付ける。`reply-secret`（0600）があれば `Authorization: Bearer` を付ける。

返事の JSON は `{ "v": 1, "cursor", "replies": [{ "id", "chat_id", "in_reply_to_guid", "text", "created_at" }] }`。`in_reply_to_guid` と `created_at` は必須。送り先は、webhook に渡したときの guid と chat_id の対応から決める。対応が無い返事や、取得元の chat_id と食い違う返事は送らない。cursor は、そのページの id 付き返事を処理し終えるまで進めない。1ページは 100 件までを想定し、壊れた要素は飛ばしてログに残す。

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

- 呼び出しの合図: 決定: 🧞🧞‍♀️🧞‍♂️（旧案の🤖は廃止）。
- 返事の経路: B案。ボットが返事を決まった場所に書き、アプリが取りに行って検査してから送る。置き場所は設計で決める。
- 返事していいトーク: 許可リスト制。トークごとにオン・オフで、初期状態は全部オフ。
- 返信の印: 先頭に「🗨️🧞‍♂️」。
- 署名: Apple Development 証明書（署名用の証明書だけ Keychain）。
- ボットの役割: 何でも答える汎用アシスタント（Grok Bot の webhook ルーチン）。
- 動かすMacは同じApple IDにつき1台だけ。ちひろ専用の値はコードに書かず、すべて設定から読む。

詳しくは `SPEC.md` 7章。
