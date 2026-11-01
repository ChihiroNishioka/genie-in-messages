# 教訓

送る前に、相手のトークが許可したときの識別子のままかを確かめる。番号が同じでも、識別子が違えば送らない。一覧との最初の照らし合わせが終わるまでは、返事を取ってこない。

個人の Notion の ID や、トークン、個人のメール、電話番号、住所を README やテストに書かない。仕様の架空の値（`example.com` と、`0000` が並ぶ番号）と、それとわかるダミーの ID だけを置く。

これを守るもの:

- `Tests/GenieCoreTests/StartupSendTests.swift` は、照らし合わせの前に返事を取らず送らないことと、番号が同じでも識別子が違うときは送らないことを、送ったかどうかで見る。
- `scripts/check-tracked-text.py` は、追跡されているファイルに秘密、トークン、個人のメール、電話番号、住所、個人の Notion ID の形が無いかを見る。出力はファイルと種類だけ。
- `Tests/GenieCoreTests/NotionReplyTests.swift` の `testPersonalIdentifiersStayOutOfDocsAndTests` が、その検査を `Sources` だけでなく README とテストも含む追跡ファイル全体に対して実行する。
- `.github/workflows/ci.yml` の `secrets` ジョブが、同じ検査を CI で実行する。権限は `contents: read` だけ。
