import Foundation

enum JobSenderHandle {
    static func isContractValue(_ value: String) -> Bool {
        guard (1...256).contains(value.utf8.count), value.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return false
        }
        let pattern = #"\A(?:tel:\+?[0-9]{1,20}|email:[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9-]+(\.[a-z0-9-]+)+)\z"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
