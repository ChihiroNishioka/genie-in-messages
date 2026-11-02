# 教訓

送る前に、相手のトークが許可したときの識別子のままかを確かめる。番号が同じでも、識別子が違えば送らない。一覧が空、そのトークが一覧に無い、一覧の取得に失敗したときも送らない。一覧との最初の照らし合わせが終わるまでは、返事を取ってこない。

個人の Notion の ID（ダッシュありの UUID と、notion.so の URL に入るダッシュなしの32桁で、十六進の種類が多いもの）や、`secret_` と `ntn_` で始まる長いトークン、そのほかのトークン、個人のメール、区切りのある電話番号を、README やテストに書かない。許すのは `example.com` / `example.org` / `example.net` / `.example`、数字に `0000` が並ぶ架空の番号、十六進の種類が少ないダミーの ID だけ。郵便番号（〒）と、英語の Street / Avenue / Road / Boulevard の並びも検査する。住所全般は見ていない。

これを守るもの:

- `Tests/GenieCoreTests/StartupSendTests.swift` は、照らし合わせの前、一覧が空のとき、許可したトークが一覧に無いとき、データベースの入れ替えリセットが起きないまま guid だけ違うときに、送信が0回であることを見る。
- `scripts/check-tracked-text.py` は、追跡されているファイルを上の範囲で見る。出力はファイルと種類だけ。
- `Tests/GenieCoreTests/TrackedTextTests.swift` は、実行時に組み立てた架空の見本で、ダッシュなしの ID と `secret_` / `ntn_` のトークンを検出できることを見る。
- `Tests/GenieCoreTests/NotionReplyTests.swift` の `testPersonalIdentifiersStayOutOfDocsAndTests` が、同じ検査を追跡ファイル全体に対して実行する。
- `.github/workflows/ci.yml` の `secrets` ジョブが、同じ検査を CI で実行する。権限は `contents: read` だけ。

照合できずに返事を送らなかったときは、黙って待たせない。一覧が空、一覧に無い、一覧の取得に失敗、guid が違う、のどれでも、メニューの「照合」の行とログに短い理由を出す。番号、メール、識別子は出さない。一覧の取得が失敗し続けても、メニューは変わる。送らない判断そのものは変えない。照合の行は最後のエラーとは別で、ほかのエラーを上書きしないし、消さない。

表示が消えるときも、理由で違う。一覧が空、一覧に無い、一覧を読めないときは返事を捨てず、次の取得まで待つ。その表示は、待っていた返事が期限を過ぎて捨てられたとき、または一覧で許可したトークの guid を確かめられたときに消える。一覧を読めない表示は、一覧を読み直せたときにも消える。guid が違うときは、その返事をその場で捨てる。その表示は、あとから guid が一致したときに消え、期限切れでは消えない。捨てた返事の表示は、ほかの理由で上書きされても、guid が合うまで残す。

これを守るもの:

- `Tests/GenieCoreTests/UnverifiedSendNoticeTests.swift` は、その4つの場合に送信が0回のまま、照合の行の文とログのコードが出て、ログに識別子が無いことを見る。
- `Tests/GenieCoreTests/HoldNoticeLifetimeTests.swift` は、照合の表示がほかのエラーを消さないこと、待っていた返事が期限切れになるか一覧が戻ると空一覧と一覧に無い表示が消えること、読み直すと一覧失敗の表示だけが消えほかのエラーは残ることを見る。
- `Tests/GenieCoreTests/MismatchNoticeStickyTests.swift` は、不一致の表示が一覧の失敗のあと読み直しても、別の返事の表示で上書きされたあと期限が切れても、guid が合うまでは「照合: なし」にならないことを見る。guid が合えば消える。
- `Sources/GenieCore/SendHoldStatus.swift` がメニューに出す文で、メニューバーアプリも同じ関数を使う。
