import Testing
@testable import WingcordCore

/// Discord's Go Live table, held to the bundle: module 753070's entries, read
/// through its `canStreamWithSettings` and the tier table beside
/// `canUseEmojisEverywhere`.
@Suite("Go Live quality")
struct GoLiveQualityTests {

    @Test("Discord's labels and boxes: four by three at 480, sixteen by nine above")
    func labelsAndBoxes() {
        #expect(StreamResolution.allCases.map(\.label) == ["480p", "720p", "1080p", "1440p", "Source"])
        #expect(StreamFrameRate.allCases.map(\.label) == ["15 FPS", "30 FPS", "60 FPS"])
        #expect(StreamResolution.p480.box == (640, 480))
        #expect(StreamResolution.p1080.box == (1_920, 1_080))
        #expect(StreamResolution.source.box == (3_840, 2_160))
    }

    @Test("Without Nitro or boosts: 720p and 480p at 15 or 30, and nothing else")
    func free() {
        let gate = GoLiveGate(premiumTier: .none, guildBoostTier: 0)
        for resolution in StreamResolution.allCases {
            for rate in StreamFrameRate.allCases {
                let expected = (resolution == .p720 || resolution == .p480) && rate != .fps60
                #expect(gate.allows(resolution, rate) == expected, "\(resolution) \(rate)")
            }
        }
        #expect(!GoLiveGate(premiumTier: .basic, guildBoostTier: 0).allows(.p1080, .fps30), "Basic buys no stream quality")
    }

    @Test("Nitro Classic and boost level 2 open 1080p and 1440p; only Nitro opens Source")
    func midAndHigh() {
        let classic = GoLiveGate(premiumTier: .classic, guildBoostTier: 0)
        #expect(classic.allows(.p1440, .fps60))
        #expect(classic.allows(.p720, .fps60))
        #expect(!classic.allows(.source, .fps30))

        let boosted = GoLiveGate(premiumTier: .none, guildBoostTier: 2)
        #expect(boosted.allows(.p1080, .fps60))
        #expect(!boosted.allows(.source, .fps15))

        let levelOne = GoLiveGate(premiumTier: .none, guildBoostTier: 1)
        #expect(levelOne.allows(.p720, .fps60))
        #expect(!levelOne.allows(.p1080, .fps30))

        let nitro = GoLiveGate(premiumTier: .nitro, guildBoostTier: 0)
        #expect(StreamResolution.allCases.allSatisfy { resolution in
            StreamFrameRate.allCases.allSatisfy { nitro.allows(resolution, $0) }
        })
    }

    /// Fake Nitro's stream quality: every option, as the plugin's patch of
    /// `canStreamQuality` gives — the server enforces none of them.
    @Test("Fake Nitro opens every resolution at every rate")
    func unlocked() {
        let gate = GoLiveGate(premiumTier: .none, guildBoostTier: 0, isUnlocked: true)
        #expect(StreamResolution.allCases.allSatisfy { resolution in
            StreamFrameRate.allCases.allSatisfy { gate.allows(resolution, $0) }
        })
        let chosen = GoLiveSettings(resolution: .source, frameRate: .fps60)
        #expect(gate.admit(chosen) == chosen)
    }

    @Test("A choice the account no longer has falls back to Discord's default")
    func admit() {
        let gate = GoLiveGate(premiumTier: .none, guildBoostTier: 0)
        let chosen = GoLiveSettings(resolution: .source, frameRate: .fps60, sharesAudio: false)
        #expect(gate.admit(chosen) == GoLiveSettings(resolution: .p720, frameRate: .fps30, sharesAudio: false))
        let allowed = GoLiveSettings(resolution: .p480, frameRate: .fps15)
        #expect(gate.admit(allowed) == allowed)
    }
}
