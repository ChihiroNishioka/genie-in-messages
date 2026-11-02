import Foundation

/// メニューの「照合」に出す、照合できずに送らなかった理由。
/// 最後のエラーとは別の行。番号、メールアドレス、識別子は含めない。
package enum SendHoldStatus {
    package static func menuLine(for code: String?) -> String {
        "照合: \(text(for: code))"
    }

    package static func text(for code: String?) -> String {
        switch code {
        case "reply_held_empty_list":
            return "トーク一覧が空のため、返事を待っています"
        case "reply_held_not_in_list":
            return "一覧に無いトークのため、返事を待っています。chats_limit を増やすと入ることがあります"
        case "chats_failed", "chats_parse_failed":
            return "トーク一覧を読めないため、返事を待っています"
        case "reply_chat_guid_mismatch":
            return "トークの識別子が変わったため、その返事は捨てました"
        default:
            return "なし"
        }
    }
}
