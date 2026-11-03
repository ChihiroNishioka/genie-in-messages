# エージェント向けの決まり

このリポジトリで作業するエージェント（と人）が守ること。詳しくは [`docs/local-verification.md`](docs/local-verification.md)。

## 検証

- 普段の検証は、ローカルの Mac mini で `python3 tools/local/verify.py`。秘密の検査、`swift test`（上限 15 分）、`swift build --product GenieMenuBar`（上限 15 分）。
- 壊し方（変異テスト）は普段の検証と分ける。関係する変更をしたときだけ `python3 tools/local/mutants.py`（上限 30 分）。全件（`--all`）は明示して頼まれたときだけ。
- 上限は watchdog が守る。超えたら子孫まで止めて 124。止まらないテストは原因を直す。再試行や上限の延長で隠さない。
- 重い検証（テスト、ビルド、壊し方）は同時に1つ。ロックが取れなければ待つか、あとで動かす。
- 失敗、タイムアウト、未実施を成功として報告しない。報告には、コマンド、SHA、結果、時間、動かさなかったものとその理由を書く。
- macOS で Linux の検証を済ませたことにしない。

## 作業場所

- エージェントごとに `git worktree` を分ける。メインのチェックアウトは触らない。
- 未コミットの変更を消さない。`reset --hard`、`clean -f`、`checkout -- .` の前に確かめる。

## テスト

- テストはモックと架空のデータだけを使う。実際の iMessage を送らない。本番の設定とデータ（`~/.config/genie-in-messages/`、`chat.db`）に触らない。
- テストは sleep しない。時計を進める（`LESSONS.md`）。

## 触らないもの

- 本番のアプリ（`/Applications/Genie.app` の `GenieMenuBar` と、その子の `imsg watch`）を止めない、入れ替えない、起動し直さない。
- GitHub Actions は手動起動（`workflow_dispatch`）だけ。`push`、`pull_request`、`schedule` などの自動起動を戻さない。
- 自前のランナーを登録しない。課金の設定を変えない。
- リポジトリの公開状態を決めつけない。2026-11-04 時点では非公開。
- 枝を push する前に、main の CI 変更（5c0cff4）を取り込む。
