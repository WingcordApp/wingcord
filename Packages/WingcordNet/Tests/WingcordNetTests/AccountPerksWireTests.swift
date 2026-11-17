import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `user.perks`: where the Vice City campaign's font perk shows up once the
/// account has joined (docs/ACTIVITY-CARDS.md decision 4).
@Suite("Account perks on the wire")
struct AccountPerksWireTests {

    private static func update(_ json: String) throws -> GatewayUpdate? {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        return GatewayUpdate(frame.payload)
    }

    @Test("READY's own user carries the campaign's source on display name styles")
    func readyCarriesTheCampaign() throws {
        let ready = ReadySnapshot(payload: try JSONDecoder().decode(ReadyPayload.self, from: Data("""
        { "session_id": "s",
          "user": { "id": "1", "username": "reader",
                    "perks": { "active_perks_bitmask": ["4"], "rules_version": 3,
                               "config_by_perk": { "2": { "source": [4],
                                   "kind": { "type": 2, "is_restricted_to_allowed_options": true, "allowed_styles": [] } } } } } }
        """.utf8)))
        #expect(ready.perks?.hasCampaignDisplayNameStyle == true)

        let plain = ReadySnapshot(payload: try JSONDecoder().decode(ReadyPayload.self, from: Data("""
        { "session_id": "s", "user": { "id": "1", "username": "reader" } }
        """.utf8)))
        #expect(plain.perks == nil)
    }

    @Test("USER_UPDATE after joining says so")
    func userUpdateCarriesIt() throws {
        let update = try Self.update("""
        {"op": 0, "s": 9, "t": "USER_UPDATE", "d": {"id": "1", "username": "reader",
          "perks": {"config_by_perk": {"2": {"source": [1, 4]}}}}}
        """)
        guard case .currentUserUpdated(_, _, _, _, let perks) = update else {
            Issue.record("not a user update")
            return
        }
        #expect(perks?.hasCampaignDisplayNameStyle == true)
        #expect(perks?.sources["2"] == [1, 4])
    }
}
