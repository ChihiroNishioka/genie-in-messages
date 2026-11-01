# 教訓

送る前に、相手のトークが許可したときの識別子のままかを確かめる。番号が同じでも、識別子が違えば送らない。一覧が空、そのトークが一覧に無い、一覧の取得に失敗したときも送らない。一覧との最初の照らし合わせが終わるまでは、返事を取ってこない。

個人の Notion の ID（ダッシュありの UUID と、notion.so の URL に入るダッシュなしの32桁で、十六進の種類が多いもの）や、`secret_` と `ntn_` で始まる長いトークン、そのほかのトークン、個人のメール、区切りのある電話番号を、README やテストに書かない。許すのは `example.com` / `example.org` / `example.net` / `.example`、数字に `0000` が並ぶ架空の番号、十六進の種類が少ないダミーの ID だけ。郵便番号（〒）と、英語の Street / Avenue / Road / Boulevard の並びも検査する。住所全般は見ていない。

これを守るもの:

- `Tests/GenieCoreTests/StartupSendTests.swift` は、照らし合わせの前、一覧が空のとき、許可したトークが一覧に無いとき、データベースの入れ替えリセットが起きないまま guid だけ違うときに、送信が0回であることを見る。
- `scripts/check-tracked-text.py` は、追跡されているファイルを上の範囲で見る。出力はファイルと種類だけ。
- `Tests/GenieCoreTests/TrackedTextTests.swift` は、実行時に組み立てた架空の見本で、ダッシュなしの ID と `secret_` / `ntn_` のトークンを検出できることを見る。
- `Tests/GenieCoreTests/NotionReplyTests.swift` の `testPersonalIdentifiersStayOutOfDocsAndTests` が、同じ検査を追跡ファイル全体に対して実行する。
- `.github/workflows/ci.yml` の `secrets` ジョブが、同じ検査を CI で実行する。権限は `contents: read` だけ。
