import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Where the application form's verification row gets its two answers — the
/// reader's own `verified` and `phone`, and the server's level — and the one
/// write the row makes.
@Suite("Account verification on the wire")
struct AccountVerificationWireTests {

    private static func snapshot(_ json: String) throws -> ReadySnapshot {
        ReadySnapshot(payload: try JSONDecoder().decode(ReadyPayload.self, from: Data(json.utf8)))
    }

    private static func update(_ json: String) throws -> GatewayUpdate? {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        return GatewayUpdate(frame.payload)
    }

    @Test("READY's own user says whether the e-mail is confirmed and a phone is held")
    func readyCarriesIt() throws {
        let verified = try Self.snapshot("""
        { "session_id": "s",
          "user": { "id": "1", "username": "reader", "verified": true, "phone": "+40700000000" } }
        """)
        #expect(verified.accountVerification == AccountVerification(isEmailVerified: true, isPhoneVerified: true))

        let noPhone = try Self.snapshot("""
        { "session_id": "s",
          "user": { "id": "1", "username": "reader", "verified": false, "phone": null } }
        """)
        #expect(noPhone.accountVerification == AccountVerification(isEmailVerified: false, isPhoneVerified: false))

        // A public object says nothing, and nothing is assumed.
        let silent = try Self.snapshot(#"{ "session_id": "s", "user": { "id": "1", "username": "reader" } }"#)
        #expect(silent.accountVerification == nil)
    }

    @Test("USER_UPDATE carries it, so a confirmed e-mail reaches an open form")
    func userUpdateCarriesIt() throws {
        let update = try Self.update("""
        {"op": 0, "s": 4, "t": "USER_UPDATE", "d": {"id": "1", "username": "reader", "verified": true}}
        """)
        guard case .currentUserUpdated(_, _, _, let verification, _) = update else {
            Issue.record("not a user update")
            return
        }
        #expect(verification == AccountVerification(isEmailVerified: true, isPhoneVerified: false))
    }

    @Test("A server's level is read at the top level and from READY's properties")
    func guildLevel() throws {
        let ready = try Self.snapshot("""
        { "session_id": "s", "user": { "id": "1", "username": "reader" },
          "guilds": [
            { "id": "10", "verification_level": 4 },
            { "id": "11", "properties": { "id": "11", "name": "Nested", "verification_level": 1 } },
            { "id": "12" }
          ] }
        """)
        let levels = Dictionary(uniqueKeysWithValues: ready.guilds.map { ($0.id.rawValue, $0.verificationLevel) })
        #expect(levels[10] == .veryHigh)
        #expect(levels[11] == .low)
        #expect(levels[12] == .some(nil))
    }

    @Test("The form's own server header carries the level for an outsider")
    func formGuildLevel() async throws {
        let body = """
        {"version":"v","form_fields":[],"guild":{"id":"1","name":"Yoho Club","verification_level":2}}
        """
        let (rest, _) = await RequestRecorder.client(body: body)
        let form = try await rest.memberVerification(of: GuildID(rawValue: 1), inviteCode: nil, withGuild: true)
        #expect(form.guild?.verificationLevel == .medium)
    }

    @Test("Verify and Resend Email post to the resend route with no body")
    func resend() async throws {
        let (rest, token) = await RequestRecorder.client(status: 204, body: "")
        try await rest.resendVerificationEmail()
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/auth/verify/resend")
        #expect(request.json == nil)
    }
}
