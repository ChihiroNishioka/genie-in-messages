import Foundation

/// 送信者ハンドルの比較キー。電話番号とメールで規則が違う。
enum SenderHandle {
    /// 比較できる形。空や、電話番号として読めない文字列は nil。
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("@") {
            return "email:" + trimmed.lowercased()
        }
        return normalizePhone(trimmed)
    }

    private static func normalizePhone(_ raw: String) -> String? {
        var digits = ""
        var sawPlus = false
        var seenDigit = false
        for scalar in raw.unicodeScalars {
            let folded = fold(scalar)
            if folded == "+" {
                if !seenDigit && !sawPlus {
                    sawPlus = true
                }
                continue
            }
            if (48...57).contains(folded.value) {
                digits.append(Character(folded))
                seenDigit = true
                continue
            }
            if CharacterSet.letters.contains(folded) {
                return nil
            }
        }
        guard !digits.isEmpty else { return nil }

        // 先頭の 00 は国際電話のプレフィックス。+ と同じ規則に乗せる。
        if !sawPlus, digits.hasPrefix("00"), digits.count > 2 {
            sawPlus = true
            digits = String(digits.dropFirst(2))
            guard !digits.isEmpty else { return nil }
        }

        if sawPlus, digits.hasPrefix("81") {
            let national = japanNational(String(digits.dropFirst(2)))
            guard !national.isEmpty else { return nil }
            return "tel:" + national
        }
        if !sawPlus, isBareJapanCountry(digits) {
            let national = japanNational(String(digits.dropFirst(2)))
            guard !national.isEmpty else { return nil }
            return "tel:" + national
        }
        if sawPlus {
            return "tel:+" + digits
        }
        return "tel:" + digits
    }

    /// `+81` を外した残りを国内形式にする。先頭が 0 でなければ 0 を足す。
    private static func japanNational(_ rest: String) -> String {
        guard !rest.isEmpty else { return rest }
        if rest.hasPrefix("0") { return rest }
        return "0" + rest
    }

    /// `+` の無い `81` は、携帯の桁のときだけ国番号とみなす。
    /// 12桁（81 + 国内10桁）か、13桁で国番号の直後が 0。
    private static func isBareJapanCountry(_ digits: String) -> Bool {
        guard digits.hasPrefix("81") else { return false }
        if digits.count == 12 { return true }
        if digits.count == 13, digits.dropFirst(2).hasPrefix("0") { return true }
        return false
    }

    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0xFF10...0xFF19:
            return Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!
        case 0xFF0B:
            return "+"
        default:
            return scalar
        }
    }
}

package struct AllowedSender: Equatable, Sendable, Codable {
    package var handle: String
    package var name: String

    package init(handle: String, name: String) {
        self.handle = handle
        self.name = name
    }

    /// 表示名。空ならハンドルではなく `sender`。
    package var payloadName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if TextNormalizer.isBlank(trimmed) { return "sender" }
        return trimmed
    }

    enum CodingKeys: String, CodingKey {
        case handle, name
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = try container.decodeIfPresent(String.self, forKey: .handle) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handle, forKey: .handle)
        try container.encode(name, forKey: .name)
    }
}

package struct ChatSenders: Equatable, Sendable, Codable {
    package var chatID: Int64
    package var senders: [AllowedSender]

    package init(chatID: Int64, senders: [AllowedSender]) {
        self.chatID = chatID
        self.senders = senders
    }

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case senders
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try container.decodeIfPresent(Int64.self, forKey: .chatID) ?? 0
        senders = try container.decodeIfPresent([AllowedSender].self, forKey: .senders) ?? []
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chatID, forKey: .chatID)
        try container.encode(senders, forKey: .senders)
    }
}

enum SenderAllowlist {
    /// グループか、外部の参加者がいるトークだけを見る。
    /// 自分宛て（グループでなく participants が空）の is_from_me=false はここに来ても一致させない。
    static func match(
        sender: String,
        chatID: Int64?,
        isGroup: Bool,
        participants: [String],
        lists: [ChatSenders]
    ) -> AllowedSender? {
        guard isGroup || !participants.isEmpty else { return nil }
        guard let chatID else { return nil }
        guard let key = SenderHandle.normalize(sender) else { return nil }
        for list in lists where list.chatID == chatID {
            if let found = list.senders.first(where: { SenderHandle.normalize($0.handle) == key }) {
                return found
            }
        }
        return nil
    }
}
