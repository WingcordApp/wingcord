import Foundation
import Testing
@testable import WingcordCore

/// The stage's decisions, each against Discord's own function.
@Suite("Stage rules")
struct StageRulesTests {

    // MARK: The age gate (module 418208)

    /// Discord's `uE` is "verified or inferred adult" and nothing else, so an
    /// account it has not placed is held back — unlike the account page, which
    /// calls an absent status an adult.
    @Test(
        "Speaking is withheld from everybody but a confirmed adult",
        arguments: [
            (nil as Int?, true), (1, true), (2, true), (3, false), (4, false), (5, true),
        ]
    )
    func withholdsUnlessAdult(status: Int?, withheld: Bool) {
        let gate = StageAgeGate(features: .stageSpeaking, ageVerificationStatus: status)
        #expect(gate.withholdsSpeaking == withheld)
    }

    @Test("Outside a gated region nothing is withheld")
    func ungatedRegion() {
        let gate = StageAgeGate(features: AgeGatedFeatures(rawValue: 1 | 64), ageVerificationStatus: 1)
        #expect(!gate.withholdsSpeaking)
        #expect(!gate.isTeen)
    }

    @Test("A teen is either of Discord's two teen statuses")
    func teen() {
        #expect(StageAgeGate(features: .stageSpeaking, ageVerificationStatus: 2).isTeen)
        #expect(StageAgeGate(features: .stageSpeaking, ageVerificationStatus: 5).isTeen)
        #expect(!StageAgeGate(features: .stageSpeaking, ageVerificationStatus: 1).isTeen)
    }

    // MARK: The waiting music (module 30108)

    private func music(
        stage: Bool = true, deaf: Bool = false, requested: Bool = false,
        live: Bool = false, muted: Bool = false, speaker: Bool = false
    ) -> StageMusic.Playback {
        StageMusic.playback(
            isInStageChannel: stage, isDeafened: deaf, isRequested: requested,
            isLive: live, isMuted: muted, hasUnmutedSpeaker: speaker
        )
    }

    @Test("It plays while the room waits, and only then")
    func waitingRoomPlays() {
        #expect(music() == .playing)
        #expect(music(speaker: true) == .paused)
        #expect(music(muted: true) == .paused)
        #expect(music(live: true) == .stopped)
        #expect(music(stage: false) == .stopped)
    }

    /// Discord's `I()` asks the deafen before anything else, the reader's
    /// Unmute Music included.
    @Test("A deafen silences even music the reader asked for")
    func deafenWins() {
        #expect(music(deaf: true, requested: true) == .stopped)
    }

    @Test("Music the reader asked for plays over a live stage")
    func requestedPlaysOverLive() {
        #expect(music(requested: true, live: true, speaker: true) == .playing)
    }

    @Test("The persistent mute is offered only while the room waits")
    func waitingButton() {
        #expect(StageMusic.isWaiting(isConnected: true, isLive: false, hasUnmutedSpeaker: false))
        #expect(!StageMusic.isWaiting(isConnected: true, isLive: true, hasUnmutedSpeaker: false))
        #expect(!StageMusic.isWaiting(isConnected: true, isLive: false, hasUnmutedSpeaker: true))
        #expect(!StageMusic.isWaiting(isConnected: false, isLive: false, hasUnmutedSpeaker: false))
    }

    // MARK: The capacity notice (`tl`, `to`)

    private func maxedOut(
        video: Bool = true, dismissed: Bool = false, moderator: Bool = true,
        community: Bool = true, tier: Int = 0, max: Int = 10_000, count: Int = 10_000
    ) -> Bool {
        StageVideoCapacity.isMaxedOut(
            hasVideo: video, isDismissed: dismissed, canModerate: moderator,
            isCommunity: community, premiumTier: tier, maxUsers: max, count: count
        )
    }

    @Test("A full video stage tells its moderators")
    func fullStage() {
        #expect(maxedOut())
        #expect(!maxedOut(count: 9_999))
        #expect(!maxedOut(video: false))
        #expect(!maxedOut(dismissed: true))
        #expect(!maxedOut(moderator: false))
    }

    /// Where Discord would sell a boost instead, nothing is drawn.
    @Test("The boost upsell's cases draw nothing")
    func upsellIsNotDrawn() {
        #expect(!maxedOut(community: true, max: 300, count: 300))
        #expect(!maxedOut(community: false, tier: 2, max: 150, count: 150))
        #expect(maxedOut(community: false, tier: 3, max: 150, count: 150))
        #expect(maxedOut(community: false, tier: 2, max: 300, count: 300))
    }

    @Test("A non-community server past three hundred is never full")
    func largeNonCommunity() {
        #expect(!maxedOut(community: false, tier: 3, max: 301, count: 400))
    }

    // MARK: The copy

    @Test("Who is speaking, Discord's four forms")
    func speakingLine() {
        #expect(StageCopy.speakingLine([]) == "No one is currently speaking")
        #expect(StageCopy.speakingLine(["ada"]) == "ada is currently speaking")
        #expect(StageCopy.speakingLine(["ada", "bob"]) == "ada and bob are currently speaking")
        #expect(StageCopy.speakingLine(["ada", "bob", "cy"]) == "ada, bob, and 1 other are currently speaking")
        #expect(StageCopy.speakingLine(["ada", "bob", "cy", "di"]) == "ada, bob, and 2 others are currently speaking")
    }

    @Test("Who is waiting keeps Discord's comma before the and")
    func waitingLine() {
        #expect(StageCopy.waitingLine([]) == nil)
        #expect(StageCopy.waitingLine(["ada"]) == "ada is currently waiting")
        #expect(StageCopy.waitingLine(["ada", "bob"]) == "ada, and bob are currently waiting")
        #expect(StageCopy.waitingLine(["ada", "bob", "cy", "di"]) == "ada, bob, and 2 others are currently waiting")
    }

    @Test("An empty stage is '0 is speaking'")
    func speakingCount() {
        #expect(StageCopy.speakingCount(0) == "0 is speaking")
        #expect(StageCopy.speakingCount(1) == "1 speaking")
        #expect(StageCopy.speakingCount(12) == "12 speaking")
    }
}
