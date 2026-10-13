import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The reader's tier and age status, read out of READY's own `user`, and the
/// reader's row surviving the thinner copies READY's arrays carry of them.
///
/// **Why this is pinned**: a Nitro account saw every other server's emoji
/// locked. The tier rode on the reader's row in the user table, READY wrote
/// that row first, and every array after it assigned whole — so any copy of
/// the reader in a member list or the deduplicated `users` array replaced the
/// one object that carried `premium_type`.
struct ReadyEntitlementsTests {

    private static func snapshot(_ json: String) throws -> ReadySnapshot {
        ReadySnapshot(payload: try JSONDecoder().decode(ReadyPayload.self, from: Data(json.utf8)))
    }

    @Test("READY's user carries the tier and the age status; nothing else may replace them")
    func readerSurvivesThinCopies() throws {
        let ready = try Self.snapshot("""
        {
          "session_id": "s",
          "user": {
            "id": "1", "username": "reader",
            "premium_type": 2, "age_verification_status": 4
          },
          "guilds": [
            { "id": "10", "members": [ { "user": { "id": "1", "username": "reader" }, "roles": [] } ] }
          ],
          "users": [ { "id": "1", "username": "reader" } ]
        }
        """)
        #expect(ready.premiumType == 2)
        #expect(ready.ageVerificationStatus == 4)
        let reader = try #require(ready.users[UserID(rawValue: 1)])
        #expect(reader.decoration?.premiumTier == .nitro)
    }

    @Test("A READY without the private fields says so, rather than saying zero")
    func absentIsNotZero() throws {
        let ready = try Self.snapshot("""
        { "session_id": "s", "user": { "id": "1", "username": "reader" } }
        """)
        #expect(ready.premiumType == nil)
        #expect(ready.ageVerificationStatus == nil)
        #expect(ready.ageGatedFeatures.isEmpty)
    }

    /// `regional_feature_config.age_gated_features` — what Discord's
    /// `RegionalFeatureConfigStore` reads — with STAGE_SPEAKING (128) set.
    @Test("The region's age-gated features come off READY")
    func regionalGate() throws {
        let ready = try Self.snapshot("""
        {
          "session_id": "s", "user": { "id": "1", "username": "reader" },
          "regional_feature_config": {
            "age_gated_features": 129, "teen_by_default_settings": 0,
            "should_collect_app_store_signal": false
          }
        }
        """)
        #expect(ready.ageGatedFeatures.contains(.stageSpeaking))
    }

    /// Never captured off a real READY, so a shape nobody expected must cost
    /// the gate and nothing else.
    @Test("A regional config of the wrong shape gates nothing and READY survives")
    func malformedRegionalGate() throws {
        let ready = try Self.snapshot("""
        {
          "session_id": "s", "user": { "id": "1", "username": "reader" },
          "regional_feature_config": { "age_gated_features": "128" }
        }
        """)
        #expect(ready.ageGatedFeatures.isEmpty)
        let list = try Self.snapshot("""
        { "session_id": "s", "user": { "id": "1", "username": "reader" }, "regional_feature_config": [1] }
        """)
        #expect(list.ageGatedFeatures.isEmpty)
    }

    /// §5.9: READY nests a guild's own fields under `properties`.
    @Test("A stage's video limit is read from both guild shapes")
    func stageVideoLimit() throws {
        let ready = try Self.snapshot("""
        {
          "session_id": "s", "user": { "id": "1", "username": "reader" },
          "guilds": [
            { "id": "10", "properties": { "name": "nested", "max_stage_video_channel_users": 300 } },
            { "id": "11", "name": "flat", "max_stage_video_channel_users": 50 }
          ]
        }
        """)
        let limits = Dictionary(uniqueKeysWithValues: ready.guilds.map { ($0.id.rawValue, $0.maxStageVideoUsers) })
        #expect(limits[10] == 300)
        #expect(limits[11] == 50)
    }
}
