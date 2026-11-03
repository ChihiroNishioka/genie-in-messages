# ローカルでの検証（Mac mini）

普段のテストとビルドは、ローカルの Mac mini で行う。GitHub Actions は 2026-11-03 のコミット 5c0cff4 から手動起動（`workflow_dispatch`）だけで、push や pull request では動かない。

## 普段の検証

```bash
python3 tools/local/verify.py
```

順に次を動かし、最後に HEAD の SHA と各段の結果・時間を出す。

| 段 | コマンド | 上限 |
|---|---|---|
| 自動起動の確認 | `.github/workflows` に `push` / `pull_request` / `schedule` などが無いこと | — |
| 秘密の検査 | `python3 scripts/check-tracked-text.py` | 120 秒 |
| テスト | `swift test` | 900 秒（15 分） |
| ビルド | `swift build --product GenieMenuBar` | 900 秒（15 分） |

- 1 段でも失敗・タイムアウトなら、残りは「未実施」と書き、0 以外で終わる。上限を超えたら 124。
- 壊し方（変異テスト）はここでは動かさない。下の「壊し方」を別に動かす。
- Linux の検証はしない。Mac で通っても Linux の結果ではない。
- テストはモックと架空のデータだけを使う。実際の iMessage は送らない。本番の設定（`~/.config/genie-in-messages/`）とデータには触らない。

2026-11-04 の Mac mini（12 コア、メモリ 16 GB、Xcode 27.1、Swift 6.4）では、`swift test` が約 80 秒（239 件）、ビルドがキャッシュありで数秒。上限は実測の 10 倍ほどの余裕を残している。

## 上限と watchdog

`tools/local/watchdog.py --limit 秒 --label 名前 -- コマンド…` が、上限つきでコマンドを動かす。

- 上限を超えたら、子と孫まで TERM を送り、5 秒待って残りに KILL を送る。終了コードは 124。
- `swift test` は `xctest` を別のプロセスグループで起動し、親が死ぬと `xctest` は pid 1 の子になる。プロセスグループを止めるだけでは残るので、watchdog は 0.2 秒ごとに子孫を記録し、作業ディレクトリのパスを引数に持つ、開始後にできた孤児も止める。
- コマンドが終わったあとに子孫が残っていたら、終了コードが 0 でも失敗にする。
- Ctrl-C や TERM で止めたときも、子孫を止めてから 128+シグナル番号で終わる。

上限を延ばすときは、延ばす前の実測時間とログを残す。再試行で隠さない。止まらないテストは原因を直す。

## 重い検証は同時に1つ

`swift test`、ビルド、壊し方は、`tools/local/heavy_lock.py` のロック（`~/Library/Caches/genie-in-messages/heavy.lock`）を取ってから動かす。ほかの検証が動いていれば、待たずに 75 で終わる。待つときは `GENIE_HEAVY_LOCK_WAIT=秒`。ロックを持っていたプロセスが死んでいれば、次の人が取り直す。

```bash
python3 tools/local/heavy_lock.py --label "my check" -- swift test --filter LampIconTests
```

## エージェントごとに worktree を分ける

同じチェックアウトで2人が動かすと、`.build` と壊し方の書き換えがぶつかる。エージェント（と人）ごとに worktree を作る。

```bash
git fetch origin
git worktree add ../genie-in-messages-wt/<作業名> -b <ブランチ名> origin/main
```

メインのチェックアウト（`~/Developer/genie-in-messages`）は、本番アプリを組み立てる場所として、そのままにしておく。

## 壊し方（変異テスト）

```bash
python3 tools/local/mutants.py           # origin/main からの変更に関係するものだけ
python3 tools/local/mutants.py --list    # 選ばれるものと理由だけを出す
python3 tools/local/mutants.py --only M4 # 名前を指定
python3 tools/local/mutants.py --all     # 全件。明示したときだけ
```

- 既定では、`git diff origin/main...HEAD`、未コミットの変更、未追跡のファイルを見て、関係する壊し方だけを選ぶ。関係するのは、壊し方が書き換えるファイル、そのパッチ、落ちるはずのテストのファイル、共通のテスト部品（XCTestCase の無い `Tests/**/*.swift`）。関係が無ければ 0 件で、「合格ではなく未実施」と出す。
- 全体の上限は 1800 秒（30 分）、1 件の上限は 900 秒。超えたら 124。
- 1 件ごとに子孫まで止め、上限・中断・失敗のどれでも、書き換えたファイルを開始前の内容に戻す。最後に内容と `git status` が開始前と同じことを確かめ、違えば 3 で終わる。
- 合格は KILLED（テストが失敗を報告した）だけ。SURVIVED、TIMEOUT、RUN DID NOT TEST（テストを1件も実行しないまま終わった）、APPLY FAILED、INTERRUPTED、NOT RUN は合格にしない。NOT RUN が1件でもあれば 2 で終わる。
- 表は `tools/mutants/manifest.json`（どの OS でも）と `tools/mutants/platform-manifest.json`（`linux-*` と `macos-*`）。
- `macos-*` は macOS 以外では NOT RUN。`linux-*` を macOS で当てた結果は「macOS で実行。Linux の検証ではない」と書く。

## Linux

この Mac では Linux の検証をしない。必要なときの案:

```bash
open -a Docker   # Docker Desktop を起動（2026-11-04 時点で停止中）
docker run --rm -v "$PWD":/src -w /src swift:6.0.3 swift test
```

費用: Docker Desktop の VM が常時メモリを数 GB 使う。初回はイメージの取得（1 GB を超える）と全体のビルドで数分かかる。Apple シリコンでは arm64 版のイメージになり、CI の x86_64 とは違う。結果は「Linux（arm64 コンテナ）」として書き、CI の Linux と同じとは言わない。

## してはいけないこと

- GitHub Actions の自動起動（`push`、`pull_request`、`schedule` など）を戻さない。自前のランナーを登録しない。課金の設定を変えない。
- 本番のアプリ（`/Applications/Genie.app` の `GenieMenuBar` と、その子の `imsg watch`）を止めない、入れ替えない、起動し直さない。
- 失敗、タイムアウト、未実施を、成功として報告しない。

## 2026-11-02〜03 の止まらなかったテスト

Actions の Linux ジョブで、壊し方 GREEN24（取り消しを無視する poller）を当てた `swift test` が約4時間止まらず、メモリ不足と SIGILL で終わった。それを「落ちた（KILLED）」と数えていた。

原因はテスト用の時計 `ManualClock` にあった。

- `sleep` は時刻を進めて、すぐに戻っていた。一度も中断しないので、止まらない poller のループが協調スレッドプールのスレッドを握り続ける。
- 2 コアの Linux ランナーではスレッドが足りず、`fulfillment(timeout:)` の期限すら動けなかった。ループは `slept` に追加し続け、メモリが尽きるまで続いた。
- `testCancellingTheSupervisorDoesNotStartWatch` は poller を止めずに終わり、そのループが残りのテストのあいだ回り続けていた。

直したこと:

- `ManualClock.sleep` は毎回 `Task.yield()` で譲る。
- `sleep` の回数に上限（10,000 回）を付けた。超えたら、時計を作ったテストの名前を付けて XCTFail し、Harness を止めてエラーを投げる。止まらないループは 0.1 秒以内に「落ちる」。
- そのテストは最後に poller を止めて、終わるのを待つ。

macOS で Linux の詰まり方を真似るには `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`（協調プールを1スレッドにする）。直したあとは、この設定でも 239 件が通り、GREEN24 は約 0.07 秒で落ちる。
