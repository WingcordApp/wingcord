import Foundation

/// Where a voice message stands, and which channel it belongs to.
///
/// **One at a time, across the app.** A channel can't hold a note in `MessageBox`
/// the way it holds a draft, because a microphone is one thing: there's one
/// recording, and at most one held note waiting to be sent. So the rules live here,
/// as a value, with nothing to set up to test them. Discord's are in `eZ` and `e7`
/// of its web build; where this differs, docs/VOICE-MESSAGES.md D5 says why.
public struct VoiceNoteFlow: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case idle
        /// The microphone's open, and the bars are going by.
        case recording(ChannelID)
        /// Stopped, and waiting to be played, sent or thrown away.
        case review(ChannelID)
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// The channel the note belongs to, in either state.
    public var channelID: ChannelID? {
        switch phase {
        case .idle: nil
        case .recording(let channelID), .review(let channelID): channelID
        }
    }

    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    public var isInReview: Bool {
        if case .review = phase { return true }
        return false
    }

    /// The composer's state in one channel: a note elsewhere is nothing here.
    public func phase(in channelID: ChannelID) -> Phase {
        self.channelID == channelID ? phase : .idle
    }

    // MARK: Starting

    public enum StartAnswer: Hashable, Sendable {
        case started
        /// It's already going here: a second press isn't a second recording.
        case alreadyHere
        /// A note's held in another channel. Only the reader can say what becomes of
        /// it: Discord's card, go back or discard.
        case heldElsewhere(ChannelID)
    }

    /// Asks to start in a channel. Recording elsewhere can't happen, because leaving
    /// a channel stops the recording there (`left(_:)`), which makes that note one
    /// more held note.
    public mutating func start(in channelID: ChannelID) -> StartAnswer {
        switch phase {
        case .idle:
            phase = .recording(channelID)
            return .started
        case .recording(let current), .review(let current):
            guard current != channelID else { return .alreadyHere }
            return .heldElsewhere(current)
        }
    }

    // MARK: Stopping

    public enum StopAnswer: Hashable, Sendable {
        case review
        /// Too short to be anything but a slip of the hand. Discord drops these
        /// without a word.
        case dropped
        /// Nothing was recording.
        case nothing
    }

    /// Stops the recording, which runs this long.
    public mutating func stop(durationSeconds: Double) -> StopAnswer {
        guard case .recording(let channelID) = phase else { return .nothing }
        guard durationSeconds >= VoiceMessageLimits.minimumSeconds else {
            phase = .idle
            return .dropped
        }
        phase = .review(channelID)
        return .review
    }

    // MARK: Ending

    /// Throws away whatever there is.
    public mutating func discard() {
        phase = .idle
    }

    /// The held note went out. Only a note in review can.
    public mutating func sent() -> Bool {
        guard isInReview else { return false }
        phase = .idle
        return true
    }

    // MARK: Limits

    /// How the timer warns as the limit nears.
    public enum Warning: Hashable, Sendable {
        case none
        /// Thirty seconds left: red, blinking every half second.
        case approaching
        /// Fifteen left: every quarter second.
        case imminent

        public init(elapsedSeconds: Double) {
            if elapsedSeconds >= VoiceMessageLimits.urgentSeconds {
                self = .imminent
            } else if elapsedSeconds >= VoiceMessageLimits.warningSeconds {
                self = .approaching
            } else {
                self = .none
            }
        }

        /// How long the timer stays lit, then dark. Nil for not at all. A second under
        /// Reduce Motion, as Discord's.
        public func blinkInterval(reduceMotion: Bool) -> Double? {
            switch self {
            case .none: nil
            case .approaching: reduceMotion ? 1 : 0.5
            case .imminent: reduceMotion ? 1 : 0.25
            }
        }
    }

    /// Whether the recording has reached the limit and should stop itself.
    public static func hasReachedLimit(elapsedSeconds: Double) -> Bool {
        elapsedSeconds >= VoiceMessageLimits.maximumSeconds
    }
}

/// Whether the mic is offered at all.
///
/// **Absent, not dimmed.** A dimmed control implies a permission that could be gained,
/// and most of these aren't that. Discord's `87207`, plus a command being filled in
/// and a scheduled send, which this client's composer has and a voice message can't
/// be part of.
public struct VoiceNoteEligibility: Hashable, Sendable {
    public var isPrivate = false
    public var canSendVoiceMessages = false
    public var isForumLike = false
    /// The composer's writing a new post: Discord's `CREATE_FORUM_POST`.
    public var isWritingPost = false
    public var isEditing = false
    public var hasFiles = false
    public var isFillingCommand = false
    public var isScheduling = false

    public init(
        isPrivate: Bool = false,
        canSendVoiceMessages: Bool = false,
        isForumLike: Bool = false,
        isWritingPost: Bool = false,
        isEditing: Bool = false,
        hasFiles: Bool = false,
        isFillingCommand: Bool = false,
        isScheduling: Bool = false
    ) {
        self.isPrivate = isPrivate
        self.canSendVoiceMessages = canSendVoiceMessages
        self.isForumLike = isForumLike
        self.isWritingPost = isWritingPost
        self.isEditing = isEditing
        self.hasFiles = hasFiles
        self.isFillingCommand = isFillingCommand
        self.isScheduling = isScheduling
    }

    public var isOffered: Bool {
        guard isPrivate || canSendVoiceMessages else { return false }
        return !isForumLike && !isWritingPost && !isEditing && !hasFiles && !isFillingCommand && !isScheduling
    }
}
