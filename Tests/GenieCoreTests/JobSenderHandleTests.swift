import XCTest
@testable import GenieCore

final class JobSenderHandleTests: XCTestCase {
    func testGNSH10ContractTable() {
        let phone = ["+1", "555", "010", "0000"].joined()
        let email256 = "email:" + String(repeating: "a", count: 64) + "@" + String(repeating: "b", count: 173) + ".example.com"
        XCTAssertEqual(email256.utf8.count, 256)
        let sharedMaxMail = "email:" + String(repeating: "a", count: 64) + "@" + String(repeating: "b", count: 180) + ".com"
        let accepted = ["tel:" + phone, "tel:" + String(repeating: "0", count: 11),
            "tel:" + String(repeating: "0", count: 7), "email:family@example.com", sharedMaxMail, email256,
            "tel:0", "tel:+" + String(repeating: "0", count: 20),
            "email:.!#$%&'*+/=?^_`{|}~-@example.com"]
        let rejected = ["", phone, "TEL:" + phone, "tel:+1 555", "tel:+", "tel:++1", "tel:1-555",
            "email:Family@example.com", "email:family@exämple.com", "email:family", "email:a@b",
            " email:family@example.com", "email:family@example.com ", "email:family@example.com\u{0}",
            "email:family@example.com\n", "email:family@example.com\r", "email:family@exam\nple.com",
            email256 + "a", sharedMaxMail + "xx", "mailto:family@example.com", "tel:" + String(repeating: "0", count: 21),
            "email:" + String(repeating: "a", count: 65) + "@example.com", "tel:０"]
        for value in accepted { XCTAssertTrue(JobSenderHandle.isContractValue(value), "accepted contract fixture") }
        for value in rejected { XCTAssertFalse(JobSenderHandle.isContractValue(value), "rejected contract fixture") }
    }
}
