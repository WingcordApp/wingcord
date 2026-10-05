import Foundation
import Testing
@testable import WingcordCore

/// What a server's verification level asks of an applicant, and what answers
/// it — Discord's application form (`823591`).
@Suite("Account verification")
struct AccountVerificationTests {

    @Test("A phone for the highest level, an e-mail below it, nothing at none")
    func requirements() {
        #expect(AccountVerification.requirement(for: .none) == nil)
        #expect(AccountVerification.requirement(for: .low) == .email)
        #expect(AccountVerification.requirement(for: .medium) == .email)
        #expect(AccountVerification.requirement(for: .high) == .email)
        #expect(AccountVerification.requirement(for: .veryHigh) == .phone)
        #expect(AccountVerification.requirement(for: .unrecognised(9)) == nil)
    }

    @Test("A phone answers an e-mail requirement too; only a phone answers a phone one")
    func meeting() {
        let emailOnly = AccountVerification(isEmailVerified: true, isPhoneVerified: false)
        let phoneOnly = AccountVerification(isEmailVerified: false, isPhoneVerified: true)
        let neither = AccountVerification(isEmailVerified: false, isPhoneVerified: false)
        #expect(emailOnly.meets(.email))
        #expect(!emailOnly.meets(.phone))
        #expect(phoneOnly.meets(.email))
        #expect(phoneOnly.meets(.phone))
        #expect(!neither.meets(.email))
    }

    @Test("The level travels as Discord's integer")
    func levelCodable() throws {
        let encoded = try JSONEncoder().encode([VerificationLevel.veryHigh, .unrecognised(7)])
        #expect(String(decoding: encoded, as: UTF8.self) == "[4,7]")
        let decoded = try JSONDecoder().decode([VerificationLevel].self, from: Data("[1,3]".utf8))
        #expect(decoded == [.low, .high])
    }
}
