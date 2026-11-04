enum BodyRetryDecision: Equatable {
    case resend
    case deadLetter
}

/// The sole decision point for retrying a body send after an uncertain result.
enum BodyResendPolicy {
    static let maxResends = 1

    static func decide(resendsUsed: Int) -> BodyRetryDecision {
        resendsUsed < maxResends ? .resend : .deadLetter
    }
}
