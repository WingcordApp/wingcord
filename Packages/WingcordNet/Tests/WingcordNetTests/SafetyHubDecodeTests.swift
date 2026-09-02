import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /safety-hub/@me`. The payload below is a real capture, trimmed of
/// nothing — every field this client does not read is left in, so the
/// fixture proves the decode tolerates them rather than merely not needing
/// them.
@Suite("Safety hub")
struct SafetyHubDecodeTests {

    private let allGood = """
    {
      "classifications": [],
      "guild_classifications": [],
      "account_standing": {"state": 100},
      "is_dsa_eligible": false,
      "username": "alexsample",
      "is_appeal_eligible": true,
      "appeal_eligibility": [2],
      "expressive_modal_v2_enabled": false
    }
    """

    @Test("state 100 decodes to allGood")
    func decodesAllGood() throws {
        let dto = try JSONDecoder().decode(SafetyHubDTO.self, from: Data(allGood.utf8))
        let standing = try #require(dto.domain)
        #expect(standing.state == .allGood)
        #expect(standing.state.rank == 0)
    }

    @Test("Every documented rung round-trips through its wire value")
    func knownRungsRoundTrip() {
        let cases: [(Int, AccountStanding.State)] = [
            (100, .allGood), (200, .limited), (300, .veryLimited),
            (400, .atRisk), (500, .suspended),
        ]
        for (wireValue, expected) in cases {
            #expect(AccountStanding.State(wireValue: wireValue) == expected)
        }
    }

    @Test("A code this table has never seen is kept, not rounded to a known rung")
    func unknownRungIsKept() {
        let state = AccountStanding.State(wireValue: 999)
        #expect(state == .unknown(999))
        #expect(state.rank == nil)
    }

    @Test("No account_standing at all decodes to nil, not a guessed rung")
    func missingStandingIsNil() throws {
        let dto = try JSONDecoder().decode(SafetyHubDTO.self, from: Data("{}".utf8))
        #expect(dto.domain == nil)
    }
}
