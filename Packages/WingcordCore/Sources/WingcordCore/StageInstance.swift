import Foundation

/// A stage that is **live**.
///
/// **A stage channel and a stage are two things, and conflating them is the
/// mistake this type exists to prevent.** The channel is permanent and sits in
/// the list whether or not anything is happening in it; the *instance* is one
/// live session with a topic, and it is created when somebody starts speaking
/// and deleted when the last speaker leaves. A channel with no instance is a
/// room with the lights off — people can still be in it, and nothing is on.
///
/// `GET /stage-instances/{channel.id}` is keyed by the **channel**, not by the
/// instance's own id, which is the tell: there is at most one live stage per
/// channel and the channel is how everything addresses it.
public struct StageInstance: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var guildID: GuildID
    /// The channel this is happening in. The key everything uses.
    public var channelID: ChannelID
    /// What the host called it. Discord requires one to start a stage at all —
    /// 1 to 120 characters — which is why it is not optional here.
    public var topic: String
    public var privacyLevel: StagePrivacyLevel
    /// Set while the stage is discoverable and an invite exists for it.
    public var inviteCode: String?
    /// Whether the host kept it out of Stage Discovery.
    public var isDiscoverableDisabled: Bool
    /// The scheduled event this stage was started for, where it was.
    public var scheduledEventID: UInt64?

    public init(
        id: UInt64,
        guildID: GuildID,
        channelID: ChannelID,
        topic: String,
        privacyLevel: StagePrivacyLevel = .guildOnly,
        inviteCode: String? = nil,
        isDiscoverableDisabled: Bool = false,
        scheduledEventID: UInt64? = nil
    ) {
        self.id = id
        self.guildID = guildID
        self.channelID = channelID
        self.topic = topic
        self.privacyLevel = privacyLevel
        self.inviteCode = inviteCode
        self.isDiscoverableDisabled = isDiscoverableDisabled
        self.scheduledEventID = scheduledEventID
    }
}

/// Who may find a stage.
///
/// **`public` is gone from Discord and the value is still on the wire**, so it
/// decodes rather than being folded away — an old stage still carries a 1, and
/// a client that read every unknown value as guild-only would quietly claim a
/// public stage was private.
public enum StagePrivacyLevel: Int, Hashable, Sendable, Codable {
    /// Discoverable outside the server. Deprecated by Discord and still sent.
    case publicStage = 1
    /// Members of the server only. Everything created now.
    case guildOnly = 2

    public init(rawValue: Int) {
        self = rawValue == 1 ? .publicStage : .guildOnly
    }
}

/// Who is on a stage, and in which of its three states.
///
/// **The split is a pure function of the voice states, and it belongs here
/// rather than in the pane.** A stage is the one voice surface where the
/// audience is not a smaller version of the speakers — they are drawn
/// differently, they are counted separately in the header, and the moderator's
/// list of raised hands is a third thing again. A view that worked that out
/// from three predicates would be the only place the rule lived.
///
/// The rule, and both halves are Discord's:
///
///  - **`suppress` is what makes somebody the audience.** It is not a mute.
///    A suppressed member has no microphone on the stage at all, and lifting
///    it is what "invite to speak" does — which is why `VoiceState.isSilenced`
///    folding it in with the two mutes is right for a *tile badge* and wrong
///    for this.
///  - **`request_to_speak_timestamp` is a raised hand**, and its being a
///    timestamp rather than a flag is load-bearing: the moderator's list is in
///    the order hands went up, and a `Bool` cannot order it.
public struct StageRoster: Hashable, Sendable {
    /// Everybody who can be heard, in join order.
    public var speakers: [UserID]
    /// Everybody listening, in join order.
    public var audience: [UserID]
    /// Hands up, **oldest first** — the order they were raised.
    public var requests: [UserID]

    public init(speakers: [UserID] = [], audience: [UserID] = [], requests: [UserID] = []) {
        self.speakers = speakers
        self.audience = audience
        self.requests = requests
    }

    /// Splits a channel's voice states three ways.
    ///
    /// A raised hand is *also* in the audience — the person is still listening
    /// — so the two lists overlap by design. The moderator's queue is a view
    /// onto the audience, not a fourth place to stand.
    public static func resolve(_ states: [VoiceState]) -> StageRoster {
        var speakers: [UserID] = []
        var audience: [UserID] = []
        var requests: [(UserID, Date)] = []

        for state in states {
            if state.isSuppressed {
                audience.append(state.userID)
                if let at = state.requestToSpeakAt { requests.append((state.userID, at)) }
            } else {
                speakers.append(state.userID)
            }
        }

        return StageRoster(
            speakers: speakers,
            audience: audience,
            // **Oldest hand first, and ties broken by id.** Two hands raised in
            // the same millisecond is not hypothetical — a client sends the
            // timestamp it computed, and two of them can agree — and an
            // unstable order there is a queue that reshuffles under the
            // moderator's pointer.
            requests: requests
                .sorted { $0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 < $1.1 }
                .map(\.0)
        )
    }
}
