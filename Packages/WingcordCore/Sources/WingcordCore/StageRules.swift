import Foundation

// MARK: - A stage's rules, read out of Discord's bundle
//
// Each of these is a decision Discord's stage makes from a handful of facts,
// written here as a pure function so the pane, the tray and the player cannot
// each grow their own copy — and so a table of cases can pin it.

/// The features Discord holds back by age in the reader's region — READY's
/// `regional_feature_config.age_gated_features` (module 923495), a bitfield
/// over its `AgeGatedFeature` enum (687123). Only the bit this client acts on
/// is named.
public struct AgeGatedFeatures: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `STAGE_SPEAKING`: speaking on a stage needs a confirmed adult.
    public static let stageSpeaking = AgeGatedFeatures(rawValue: 128)
}

/// Discord's age gate on a stage's microphone (module 418208).
///
/// **Adult means 3 or 4 here, and nothing else.** The account page resolves an
/// absent status to an adult (`AgeGroup`), but the stage asks "verified or
/// inferred adult" outright (`uE`), so an account Discord has not placed is
/// held back exactly as an unverified one is.
public struct StageAgeGate: Hashable, Sendable {
    /// Whether `STAGE_SPEAKING` is age-gated where the reader is.
    public var isRegionGated: Bool
    /// `age_verification_status`, verbatim — 1 unverified, 2 verified teen,
    /// 3 verified adult, 4 inferred adult, 5 inferred teen.
    public var status: Int?

    public init(features: AgeGatedFeatures, ageVerificationStatus: Int?) {
        isRegionGated = features.contains(.stageSpeaking)
        status = ageVerificationStatus
    }

    /// Discord's `Vv`, less its channel half (which the caller holds): the
    /// region gates speaking and the account is not a confirmed adult. The hand
    /// then reads "Speaker abilities are only for confirmed adults".
    public var withholdsSpeaking: Bool {
        isRegionGated && status != 3 && status != 4
    }

    /// Discord's `zU`: a teen in a gated region, who is not offered Start the
    /// Stage, and is told why in the Start Stage dialog.
    public var isTeen: Bool {
        isRegionGated && (status == 2 || status == 5)
    }
}

/// Discord's waiting music — `stage_waiting`, looped at a quarter of the
/// output volume (module 30108, `I()`).
public enum StageMusic {
    public enum Playback: Hashable, Sendable {
        /// Silent, and back to the start next time.
        case stopped
        /// Silent, keeping its place.
        case paused
        case playing
    }

    /// What the music does now — Discord's `I()`, top to bottom.
    ///
    /// - Parameters:
    ///   - isRequested: the reader pressed Unmute Music while something was
    ///     going on — Discord's `shouldPlay`, which plays over everything but a
    ///     deafen and is forgotten when the reader moves channel.
    ///   - isMuted: the reader's Mute Music, which persists.
    ///   - hasUnmutedSpeaker: somebody — the reader included — is on the stage
    ///     with their microphone open.
    public static func playback(
        isInStageChannel: Bool,
        isDeafened: Bool,
        isRequested: Bool,
        isLive: Bool,
        isMuted: Bool,
        hasUnmutedSpeaker: Bool
    ) -> Playback {
        guard isInStageChannel, !isDeafened else { return .stopped }
        if isRequested { return .playing }
        if isLive { return .stopped }
        if isMuted || hasUnmutedSpeaker { return .paused }
        return .playing
    }

    /// Discord's `bF`: the room is still waiting — connected, nothing live and
    /// nobody speaking — and the tray's music button is the persistent Mute
    /// Music. Otherwise it is the one-off Unmute Music that plays anyway.
    public static func isWaiting(isConnected: Bool, isLive: Bool, hasUnmutedSpeaker: Bool) -> Bool {
        isConnected && !isLive && !hasUnmutedSpeaker
    }
}

/// Discord's "This Video Stage is maxed out." under a stage's header
/// (`tl` and `to` in the stage chunk).
public enum StageVideoCapacity {
    /// Whether the moderator's notice is drawn.
    ///
    /// **Only the notice, never the upsell.** Where Discord would instead offer
    /// "This Video Stage is full!" with Boost — a community server under ten
    /// thousand, or an unboosted one at 150 — this client draws nothing,
    /// because it does not sell boosts.
    ///
    /// - Parameters:
    ///   - hasVideo: somebody in the channel has a camera on, or a speaker is
    ///     streaming — what makes it a *video* stage.
    ///   - count: speakers and audience together.
    ///   - maxUsers: the server's `max_stage_video_channel_users`.
    public static func isMaxedOut(
        hasVideo: Bool,
        isDismissed: Bool,
        canModerate: Bool,
        isCommunity: Bool,
        premiumTier: Int,
        maxUsers: Int,
        count: Int
    ) -> Bool {
        guard hasVideo, !isDismissed, canModerate else { return false }
        if !isCommunity, maxUsers > 300 { return false }
        guard count >= maxUsers else { return false }
        let isUpsell = isCommunity ? maxUsers < 10_000 : premiumTier != 3 && maxUsers <= 150
        return !isUpsell
    }
}

/// The sentences a stage builds from the people in it.
public enum StageCopy {
    /// Under the join card's title (module 110618, `DO`): who is speaking now.
    public static func speakingLine(_ names: [String]) -> String {
        switch names.count {
        case 0: "No one is currently speaking"
        case 1: "\(names[0]) is currently speaking"
        case 2: "\(names[0]) and \(names[1]) are currently speaking"
        default:
            "\(names[0]), \(names[1]), and \(others(names.count - 2)) are currently speaking"
        }
    }

    /// Under the start screen's cards (`5ULgaQ`, `BHK0Op`, `T3MT4n`): who is in
    /// the room — everybody, the reader included, as Discord counts it. Nil
    /// when it is empty, where Discord draws an empty line.
    public static func waitingLine(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "\(names[0]) is currently waiting"
        case 2: "\(names[0]), and \(names[1]) are currently waiting"
        default:
            "\(names[0]), \(names[1]), and \(others(names.count - 2)) are currently waiting"
        }
    }

    /// The header's first count (`chmM9N`): Discord's plural reads "0 is
    /// speaking" for an empty stage and "N speaking" otherwise.
    public static func speakingCount(_ count: Int) -> String {
        count == 0 ? "0 is speaking" : "\(count) speaking"
    }

    private static func others(_ count: Int) -> String {
        count == 1 ? "1 other" : "\(count) others"
    }
}
