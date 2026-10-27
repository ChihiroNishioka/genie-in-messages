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

enum SelfChat {
    /// imsg は `is_group` か、識別子の `;+;` でグループを表す。
    static func resolveGroup(flag: Bool?, chatGUID: String?, chatIdentifier: String?) -> Bool {
        if flag == true { return true }
        if let chatGUID, chatGUID.contains(";+;") { return true }
        if let chatIdentifier, chatIdentifier.contains(";+;") { return true }
        return false
    }

    /// 自分宛てトークの `is_from_me=false` を無視する。
    /// グループか、外部の参加者がいる1対1なら無視しない。
    /// 参加者が空の自分宛てと、欄が無くて判定できないときは無視する（安全側）。
    static func ignoresInboundEcho(isGroup: Bool, participantsKnown: Bool, participants: [String]) -> Bool {
        if isGroup { return false }
        if participantsKnown && participants.contains(where: { !isBlankParticipant($0) }) {
            return false
        }
        return true
    }

    /// 連絡先名がハンドルそのものなら、payload に載せて番号を出さない。
    static func isHandle(_ name: String, sender: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || raw.isEmpty { return false }
        if trimmed.compare(raw, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        if let left = SenderHandle.normalize(trimmed), let right = SenderHandle.normalize(raw), left == right {
            return true
        }
        return false
    }

    private static func isBlankParticipant(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
