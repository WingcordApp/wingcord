import Foundation

/// Discord's per-person sound settings, synced across the account's devices:
/// each person's volume and whether they are muted — for their voice, and
/// apart from it for their stream. The settings proto's
/// `audio_context_settings` (field 16), read out of Discord's compiled
/// descriptor:
///
/// ```
/// AudioSettings       { map<fixed64, AudioContextSetting> user = 1; map<…> stream = 2 }
/// AudioContextSetting { bool muted = 1; float volume = 2; fixed64 modified_at = 3;
///                       bool soundboard_muted = 4 }
/// ```
///
/// **Discord's writer's rules, kept here so every write follows them** (its
/// `AudioSettingsManager`, module 386741): an entry back at its default and
/// not muted is removed rather than written; a volume within one slider-percent
/// of the default *is* the default; and each map keeps its newest 300.
public struct AudioContextSettings: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var isMuted = false
        /// The gain, as a fraction — 1 is as sent. Discord stores it ×100.
        public var volume: Double
        /// Milliseconds since 1970, which is what decides the newest 300.
        public var modifiedAt: UInt64 = 0
        public var isSoundboardMuted = false

        public init(isMuted: Bool = false, volume: Double, modifiedAt: UInt64 = 0, isSoundboardMuted: Bool = false) {
            self.isMuted = isMuted
            self.volume = volume
            self.modifiedAt = modifiedAt
            self.isSoundboardMuted = isSoundboardMuted
        }
    }

    /// Whose setting: their voice in a call, or their stream.
    public enum Context: Sendable, Hashable {
        case user
        case stream

        /// Discord's defaults: a voice as sent, a stream at 18 — about 54% on
        /// the slider, where Discord's Stream Volume starts.
        public var defaultVolume: Double {
            switch self {
            case .user: 1
            case .stream: 0.18
            }
        }
    }

    public var users: [UserID: Entry] = [:]
    public var streams: [UserID: Entry] = [:]

    /// How many entries a map keeps.
    public static let capacity = 300

    public init(users: [UserID: Entry] = [:], streams: [UserID: Entry] = [:]) {
        self.users = users
        self.streams = streams
    }

    public subscript(context: Context) -> [UserID: Entry] {
        get { context == .user ? users : streams }
        set { if context == .user { users = newValue } else { streams = newValue } }
    }

    public func volume(of userID: UserID, in context: Context) -> Double {
        self[context][userID]?.volume ?? context.defaultVolume
    }

    public func isMuted(_ userID: UserID, in context: Context = .user) -> Bool {
        self[context][userID]?.isMuted ?? false
    }

    /// Somebody's volume, as Discord writes it.
    public mutating func setVolume(_ volume: Double, of userID: UserID, in context: Context, at now: Date) {
        update(userID, in: context, at: now) { entry in
            // Within a slider-percent of the default is the default — so a
            // slider dragged back by hand removes the entry, as Discord's does.
            let isDefault = abs(VolumeCurve.position(ofGain: volume)
                - VolumeCurve.position(ofGain: context.defaultVolume)) < 0.01
            entry.volume = isDefault ? context.defaultVolume : volume
        }
    }

    public mutating func setMuted(_ muted: Bool, of userID: UserID, in context: Context = .user, at now: Date) {
        update(userID, in: context, at: now) { $0.isMuted = muted }
    }

    /// Discord's Mute Soundboard, which lives on a voice's entry.
    public mutating func setSoundboardMuted(_ muted: Bool, of userID: UserID, at now: Date) {
        update(userID, in: .user, at: now) { $0.isSoundboardMuted = muted }
    }

    private mutating func update(
        _ userID: UserID, in context: Context, at now: Date, _ change: (inout Entry) -> Void
    ) {
        var map = self[context]
        var entry = map[userID] ?? Entry(volume: context.defaultVolume)
        change(&entry)
        entry.modifiedAt = UInt64((now.timeIntervalSince1970 * 1_000).rounded())
        let isDefault = entry.volume == context.defaultVolume && !entry.isMuted && !entry.isSoundboardMuted
        map[userID] = isDefault ? nil : entry
        if map.count > Self.capacity {
            let oldest = map.sorted { $0.value.modifiedAt < $1.value.modifiedAt }
                .prefix(map.count - Self.capacity)
            for (id, _) in oldest { map[id] = nil }
        }
        self[context] = map
    }
}
