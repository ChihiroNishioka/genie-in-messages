import Foundation

package enum ErrorStatus {
    package static func menuLines(for snapshot: EngineSnapshot?) -> [String] {
        let lastError = snapshot?.lastError
        let replyFetchError = snapshot?.replyFetchError
        if let lastError, let replyFetchError {
            return [
                "最後のエラー: 送信など: \(text(lastError))",
                "返信の取得: \(text(replyFetchError))"
            ]
        }
        return ["最後のエラー: \(text(lastError ?? replyFetchError))"]
    }

    package static func text(_ code: String?) -> String {
        switch code {
        case nil, "":
            return "なし"
        case "screen_locked":
            return "画面ロック中のため送信を保留しています"
        case "screen_lock_unknown":
            return "画面ロックを確認できていません"
        case "url_not_https":
            return "webhook と返事の URL は https だけ使えます"
        case "messages_db_reset":
            return "メッセージのデータベースが変わったため、許可とカーソルを捨てました"
        case "reply_unrouted":
            return "対応する転送が無い返事は送っていません"
        case "reply_chat_mismatch":
            return "返事のトークが転送先と違うため送っていません"
        case "reply_chat_guid_mismatch":
            return SendHoldStatus.text(for: code)
        case "reply_held_empty_list", "reply_held_not_in_list", "chats_failed", "chats_parse_failed", "chats_parse_partial_ok":
            return SendHoldStatus.text(for: code)
        case "watch_line_too_large":
            return "大きすぎる watch の行を処理できませんでした"
        case "deadletter_write_failed":
            return "失敗の記録を書けませんでした"
        case "send_interrupted":
            return "送信の途中で止まったため、再送していません"
        case "apple_event_1712":
            return "送信が始まらなかったため保留しています"
        case "rate_limited":
            return "送信レートの上限で、そのトークへの返信を止めています"
        case "secret_mode":
            return "secret の権限が 600 ではありません"
        case "secret_missing":
            return "webhook の secret がありません"
        case "secret_empty":
            return "webhook の secret が空です"
        case "webhook_not_configured":
            return "webhook の URL が未設定です"
        case "watch_start_failed":
            return "imsg を起動できませんでした"
        case "watch_exited":
            return "imsg watch が終了したので再起動します"
        case "send_uncertain":
            return "送信結果が不明なため、再送していません"
        case "send_failed":
            return "送信に失敗しました。結果が不明なので再送していません"
        case "reply_fetch_failed":
            return "返事の取得に失敗しました"
        case "reply_secret_mode":
            return "reply-secret の権限が 600 ではありません"
        case "notion_token_missing":
            return "Notion トークンがありません"
        case "notion_token_mode":
            return "Notion トークンの権限が 600 ではありません"
        case "notion_token_empty":
            return "Notion トークンが空です"
        case "notion_token_unreadable":
            return "Notion トークンを保存できませんでした"
        case "state_reset":
            return "壊れていた状態ファイルを退避し、今から監視しています"
        case "allowlist_reset":
            return "壊れていた許可リストを退避し、すべてオフに戻しました"
        case "login_item_failed":
            return "ログイン時の起動を切り替えられませんでした"
        case "caffeinate_failed":
            return "caffeinate を起動できませんでした"
        default:
            return code ?? "なし"
        }
    }
}
