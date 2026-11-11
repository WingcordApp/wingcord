import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `client_status`, read by Discord's own two tests (`isMobileOnline`,
/// `isVROnline`): which device somebody's online mark is drawn as.
@Suite("Presence client")
struct PresenceClientDecodeTests {

    private func presence(_ clientStatus: String) throws -> Presence {
        let json = """
        {"user":{"id":"100"},"status":"online","client_status":\(clientStatus),"activities":[]}
        """
        let dto = try JSONDecoder().decode(PresenceDTO.self, from: Data(json.utf8))
        return try #require(dto.domain)
    }

    @Test("Online on the phone alone is a phone")
    func phoneOnly() throws {
        #expect(try presence(#"{"mobile":"online"}"#).client == .mobile)
    }

    @Test("At a desk with a phone in a pocket is at a desk")
    func deskWins() throws {
        #expect(try presence(#"{"mobile":"online","desktop":"online"}"#).client == .desktop)
    }

    @Test("Idle at the desk and online on the phone is still a phone, as Discord has it")
    func idleDesk() throws {
        #expect(try presence(#"{"mobile":"online","desktop":"idle"}"#).client == .mobile)
    }

    @Test("Idle on the phone is not a phone: the mark is only for online")
    func idlePhone() throws {
        #expect(try presence(#"{"mobile":"idle"}"#).client == .desktop)
    }

    @Test("The browser is not asked about")
    func browserIsIgnored() throws {
        #expect(try presence(#"{"mobile":"online","web":"online"}"#).client == .mobile)
    }

    @Test("A headset is a headset, whatever else is on")
    func headset() throws {
        #expect(try presence(#"{"vr":"online"}"#).client == .vr)
        #expect(try presence(#"{"vr":"online","mobile":"online"}"#).client == .vr)
        #expect(try presence(#"{"vr":"online","desktop":"online"}"#).client == .vr)
    }
}
