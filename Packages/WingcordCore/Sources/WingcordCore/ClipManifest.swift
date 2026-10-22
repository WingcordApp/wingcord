import Foundation

// MARK: - What a clip knows
//
// docs/CLIPS-PRESENCE.md, Phase 3.3. A clip is an MP4 and this: who was in the
// call, who spoke when, what the game said happened, and which audio track is
// whose. It is kept as a sidecar beside the file — the library reads it — and
// at share time it becomes the attachment's clip fields, the timeline in
// Discord's own `clip_events_timeline` shape so that Discord's player lights
// the faces up from it.

public struct ClipManifest: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public enum Kind: String, Codable, Sendable {
        /// The last seconds of a game, kept by the replay buffer.
        case clip
        case screenshot
        /// A take from the capture bar.
        case recording
    }

    /// Where the picture came from — Discord's two `ClipSource`s.
    public enum Source: String, Codable, Sendable {
        /// The game's own window, captured for clips alone (`DECOUPLED`).
        case window
        /// The reader's Go Live stream, off its encoder (`STREAMER`).
        case stream
    }

    public var version: Int
    public var id: UUID
    /// When it was saved — Discord's `clip_created_at`.
    public var createdAt: Date
    /// Seconds of picture and sound in the file.
    public var duration: Double
    public var kind: Kind
    public var source: Source
    /// Discord's `title`: nil until somebody names it.
    public var title: String?
    public var game: ClipGame?
    /// Everybody in the call during the clip, in the order they were seen.
    public var participants: [ClipParticipant]
    /// The file's audio tracks, in file order.
    public var tracks: [ClipAudioTrack]
    public var timeline: [ClipTimelineEvent]
    /// What the editor did — nil for a clip nobody has opened.
    public var edits: ClipEdits?
    /// Discord's `clipMethod`: an Auto Clip, or one somebody asked for. Nil
    /// on a sidecar from before Auto Clips — asked for.
    public var method: Method?
    /// Why an Auto Clip was kept (docs/CLIPS-PRESENCE.md, Phase 7.2).
    public var autoReason: AutoClipReason?
    /// The moment's shared id when others in the call clipped it too —
    /// Discord's `remoteClipId` (Phase 7.3).
    public var remoteClipID: String?
    /// Who clipped it first, for a clip kept because they did — Discord's
    /// "Clipped with".
    public var triggeredBy: UInt64?

    public enum Method: String, Codable, Sendable {
        case manual
        case auto
    }

    public var isAutoClip: Bool { method == .auto }

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        duration: Double,
        kind: Kind = .clip,
        source: Source = .window,
        title: String? = nil,
        game: ClipGame? = nil,
        participants: [ClipParticipant] = [],
        tracks: [ClipAudioTrack] = [],
        timeline: [ClipTimelineEvent] = []
    ) {
        version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.kind = kind
        self.source = source
        self.title = title
        self.game = game
        self.participants = participants
        self.tracks = tracks
        self.timeline = timeline
    }

    /// Discord's `clip_participant_ids`: the first hundred (`GU`), as strings.
    public var participantIDs: [String] {
        participants.prefix(ClipTimeline.participantLimit).map { String($0.userID) }
    }
}

/// The game a clip was taken in.
public struct ClipGame: Codable, Hashable, Sendable {
    /// Discord's `application_id`, when the detector knew the game.
    public var applicationID: UInt64?
    public var name: String

    public init(applicationID: UInt64?, name: String) {
        self.applicationID = applicationID
        self.name = name
    }
}

/// Somebody who was in the call, as they were then.
///
/// The name and face are kept so that the library can draw them later, offline
/// and after the person has changed both.
public struct ClipParticipant: Codable, Hashable, Sendable {
    public var userID: UInt64
    public var name: String
    public var avatarURL: URL?

    public init(userID: UInt64, name: String, avatarURL: URL? = nil) {
        self.userID = userID
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// One audio track of the file and whose sound it is.
public struct ClipAudioTrack: Codable, Hashable, Sendable {
    public enum Role: Codable, Hashable, Sendable {
        /// Everything kept, mixed — the track every player plays.
        case mix
        /// The game's own sound.
        case game
        /// The reader's microphone.
        case microphone
        /// Somebody else in the call.
        case voice(userID: UInt64)
        case soundboard
    }

    public var role: Role
    public var title: String
    /// Whether players play it by default: only the mix is.
    public var isEnabled: Bool

    public init(role: Role, title: String, isEnabled: Bool) {
        self.role = role
        self.title = title
        self.isEnabled = isEnabled
    }
}

// MARK: - The events timeline

/// One entry of Discord's `clip_events_timeline`.
///
/// The wire shape is `{timestamp_ms, speaking: {user_id, speaking_flags}}`,
/// `{timestamp_ms, game: {type, event_name}}` or
/// `{timestamp_ms, emotion: {type}}` — milliseconds from the clip's start, a
/// user id as a string.
public struct ClipTimelineEvent: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        /// A speaking state that changed. Discord's `speaking_flags`: 1 voice,
        /// 2 soundshare, 4 priority; 0 is stopped.
        case speaking(userID: UInt64, flags: Int)
        case game(type: ClipGameEventType, name: String)
        case emotion(ClipEmotion)
    }

    public var timestampMS: Int
    public var event: Event

    public init(timestampMS: Int, event: Event) {
        self.timestampMS = timestampMS
        self.event = event
    }
}

/// The game event types the wire knows (module 762555's `E`); every other
/// kind a source reports travels as `unknown` with its name.
public enum ClipGameEventType: Int, Codable, Hashable, Sendable {
    case unknown = 0
    case kill = 1
    case multikill = 2
    case death = 3
}

/// Module 762555's `A`.
public enum ClipEmotion: Int, Codable, Hashable, Sendable {
    case laughter = 1
    case shouting = 2
}

extension ClipTimelineEvent: Codable {
    private enum Keys: String, CodingKey {
        case timestamp_ms, speaking, game, emotion
    }

    private struct Speaking: Codable {
        var user_id: String
        var speaking_flags: Int
    }

    private struct Game: Codable {
        var type: Int
        var event_name: String
    }

    private struct Emotion: Codable {
        var type: Int
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        timestampMS = try container.decode(Int.self, forKey: .timestamp_ms)
        if let speaking = try container.decodeIfPresent(Speaking.self, forKey: .speaking),
           let userID = UInt64(speaking.user_id)
        {
            event = .speaking(userID: userID, flags: speaking.speaking_flags)
        } else if let game = try container.decodeIfPresent(Game.self, forKey: .game) {
            event = .game(type: ClipGameEventType(rawValue: game.type) ?? .unknown, name: game.event_name)
        } else if let emotion = try container.decodeIfPresent(Emotion.self, forKey: .emotion),
                  let kind = ClipEmotion(rawValue: emotion.type)
        {
            event = .emotion(kind)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .speaking, in: container, debugDescription: "no event this build knows"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(timestampMS, forKey: .timestamp_ms)
        switch event {
        case .speaking(let userID, let flags):
            try container.encode(Speaking(user_id: String(userID), speaking_flags: flags), forKey: .speaking)
        case .game(let type, let name):
            try container.encode(Game(type: type.rawValue, event_name: name), forKey: .game)
        case .emotion(let kind):
            try container.encode(Emotion(type: kind.rawValue), forKey: .emotion)
        }
    }
}

/// Builds the timeline the way Discord's client does (module 762555's `lz`).
///
/// - Everybody already speaking when the clip starts is one entry at 0, with
///   the voice flag — the state carried in from before the window.
/// - Inside the window, a speaking change is an entry only when it changes
///   that person's state; game events and emotions are entries as they come.
/// - Sorted by time, and at most a thousand (`td`).
///
/// Times are seconds on any one clock; `start` and `end` are the clip's
/// window on the same clock.
public enum ClipTimeline {
    /// Discord's `td`: the entries one clip carries.
    public static let eventLimit = 1_000
    /// Discord's `GU`: the participants one clip names.
    public static let participantLimit = 100
    /// `SpeakingFlags.VOICE`.
    public static let voiceFlag = 1

    public struct SpeakingChange: Hashable, Sendable {
        public var time: Double
        public var userID: UInt64
        public var flags: Int

        public init(time: Double, userID: UInt64, flags: Int) {
            self.time = time
            self.userID = userID
            self.flags = flags
        }
    }

    public struct GameMoment: Hashable, Sendable {
        public var time: Double
        public var type: ClipGameEventType
        public var name: String

        public init(time: Double, type: ClipGameEventType, name: String) {
            self.time = time
            self.type = type
            self.name = name
        }
    }

    public struct EmotionMoment: Hashable, Sendable {
        /// The peak of it.
        public var time: Double
        public var emotion: ClipEmotion

        public init(time: Double, emotion: ClipEmotion) {
            self.time = time
            self.emotion = emotion
        }
    }

    public static func events(
        start: Double,
        end: Double,
        speaking: [SpeakingChange],
        games: [GameMoment] = [],
        emotions: [EmotionMoment] = []
    ) -> [ClipTimelineEvent] {
        func milliseconds(_ time: Double) -> Int { Int(((time - start) * 1_000).rounded()) }

        let changes = speaking.sorted { $0.time < $1.time }
        var state: [UInt64: Bool] = [:]
        var carried: [UInt64] = []
        for change in changes where change.time < start {
            let isOn = change.flags & voiceFlag == voiceFlag
            if state[change.userID] == nil { carried.append(change.userID) }
            state[change.userID] = isOn
        }

        var events: [ClipTimelineEvent] = carried.compactMap { userID in
            state[userID] == true
                ? ClipTimelineEvent(timestampMS: 0, event: .speaking(userID: userID, flags: voiceFlag))
                : nil
        }
        for change in changes where change.time >= start && change.time <= end {
            let isOn = change.flags & voiceFlag == voiceFlag
            guard (state[change.userID] ?? false) != isOn else { continue }
            state[change.userID] = isOn
            events.append(ClipTimelineEvent(
                timestampMS: milliseconds(change.time),
                event: .speaking(userID: change.userID, flags: change.flags)
            ))
        }
        for moment in games where moment.time >= start && moment.time <= end {
            events.append(ClipTimelineEvent(
                timestampMS: milliseconds(moment.time), event: .game(type: moment.type, name: moment.name)
            ))
        }
        for moment in emotions where moment.time >= start && moment.time <= end {
            events.append(ClipTimelineEvent(timestampMS: milliseconds(moment.time), event: .emotion(moment.emotion)))
        }
        // Stable, as JavaScript's sort is: entries at one moment keep the
        // order they were made in.
        let ordered = events.enumerated().sorted {
            ($0.element.timestampMS, $0.offset) < ($1.element.timestampMS, $1.offset)
        }.map(\.element)
        return Array(ordered.prefix(eventLimit))
    }
}

// MARK: - A clip in a message

/// What a clip attachment says about itself — Discord's `is_clip` fields, as
/// its player reads them: the participants (user objects), the title and the
/// game, when it was made, and the events timeline it lights the faces up
/// from. docs/CLIPS-PRESENCE.md, Phase 4.1.
public struct AttachmentClip: Hashable, Sendable, Codable {
    public var title: String?
    public var applicationID: UInt64?
    public var applicationName: String?
    public var createdAt: Date?
    /// The people in it, as Discord sends them — whole users, so the faces
    /// draw without anybody being fetched.
    public var participants: [User]
    public var timeline: [ClipTimelineEvent]
    /// The shared id that ties clips of one moment from several people.
    public var remoteID: String?
    /// The attachment's `HAS_TIMELINE_COMMENTS` flag: somebody has replied at
    /// a moment of it.
    public var hasTimelineComments: Bool

    public init(
        title: String? = nil, applicationID: UInt64? = nil, applicationName: String? = nil,
        createdAt: Date? = nil, participants: [User] = [], timeline: [ClipTimelineEvent] = [],
        remoteID: String? = nil, hasTimelineComments: Bool = false
    ) {
        self.title = title
        self.applicationID = applicationID
        self.applicationName = applicationName
        self.createdAt = createdAt
        self.participants = participants
        self.timeline = timeline
        self.remoteID = remoteID
        self.hasTimelineComments = hasTimelineComments
    }

    /// Whether the timeline has speech to light faces up with — what makes
    /// Discord's player offer "Speaking indicators".
    public var hasSpeaking: Bool {
        timeline.contains { if case .speaking = $0.event { true } else { false } }
    }

    /// Who is speaking `milliseconds` into the clip — the timeline's speaking
    /// entries played forward to that moment.
    public func speakers(at milliseconds: Int) -> Set<UInt64> {
        var speaking: Set<UInt64> = []
        for entry in timeline where entry.timestampMS <= milliseconds {
            guard case .speaking(let userID, let flags) = entry.event else { continue }
            if flags & ClipTimeline.voiceFlag == ClipTimeline.voiceFlag {
                speaking.insert(userID)
            } else {
                speaking.remove(userID)
            }
        }
        return speaking
    }
}

/// What goes up with a clip being shared — Discord's upload payload's clip
/// half (module 122924's `getUploadPayload`, and the same fields on the
/// message's attachment entry).
public struct ClipUpload: Hashable, Sendable {
    public var title: String?
    public var applicationID: UInt64?
    public var createdAt: Date
    public var participantIDs: [UInt64]
    public var timeline: [ClipTimelineEvent]
    public var durationSeconds: Double?
    /// The moment's shared id — Discord's `clip_remote_id`, the same on
    /// every point of view of one moment (Phase 7.3).
    public var remoteID: String?
    /// Discord's `clip_sync_timestamp`: when it was clipped, on a clock every
    /// point of view agrees on.
    public var syncTimestamp: Date?

    public init(
        title: String?, applicationID: UInt64?, createdAt: Date, participantIDs: [UInt64],
        timeline: [ClipTimelineEvent], durationSeconds: Double?,
        remoteID: String? = nil, syncTimestamp: Date? = nil
    ) {
        self.title = title
        self.applicationID = applicationID
        self.createdAt = createdAt
        self.participantIDs = Array(participantIDs.prefix(ClipTimeline.participantLimit))
        self.timeline = Array(timeline.prefix(ClipTimeline.eventLimit))
        self.durationSeconds = durationSeconds
        self.remoteID = remoteID
        self.syncTimestamp = syncTimestamp
    }
}

/// A reply at a moment of a clip — Discord's `media_mention`, the timeline
/// comment: the attachment and the milliseconds into it.
public struct MediaMention: Hashable, Sendable, Codable {
    public var attachmentID: AttachmentID
    public var timestampMS: Int

    public init(attachmentID: AttachmentID, timestampMS: Int) {
        self.attachmentID = attachmentID
        self.timestampMS = timestampMS
    }
}

// MARK: - Points of view

/// Every clip of one moment in a conversation — Discord's distributed clips
/// (`2026-05-distributed-clips`): the clip first shared, and the replies to
/// it whose attachment carries the same `clip_remote_id`.
public enum ClipPointsOfView {
    /// One point of view.
    public struct View: Hashable, Sendable, Identifiable {
        public var attachment: Attachment
        public var messageID: MessageID
        public var authorID: UserID
        /// The one first shared — Discord's "Original".
        public var isOriginal: Bool

        public var id: AttachmentID { attachment.id }
    }

    /// The points of view of the moment `attachment` shows, oldest first, or
    /// none when it is the only one — or not a moment others clipped.
    public static func views(of attachment: Attachment, in messages: [Message]) -> [View] {
        guard let remoteID = attachment.clip?.remoteID else { return [] }
        var views: [View] = []
        for message in messages.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            for candidate in message.attachments where candidate.clip?.remoteID == remoteID {
                views.append(View(
                    attachment: candidate, messageID: message.id, authorID: message.authorID,
                    isOriginal: views.isEmpty
                ))
            }
        }
        return views.count > 1 ? views : []
    }
}
