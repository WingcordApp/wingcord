import Foundation

/// One activity running somewhere, and who is in it.
///
/// **Discord's own account of it, not this client's guess.** The gateway says
/// it in `EMBEDDED_ACTIVITY_UPDATE_V2`, and `READY_SUPPLEMENTAL` and
/// `GUILD_CREATE` carry the ones already running in each server as
/// `activity_instances`; Discord's `EmbeddedActivitiesStore` (module 933958) is
/// built from exactly these, and so is this client's (`ActivityInstances`).
///
/// **One per application per place.** Launching an app where one of it is
/// already running adds you to that one, which is why a frame must be opened on
/// the ids this names and never on the launching interaction's
/// (docs/ACTIVITIES-CALLS-PICKER.md §1, the "works half the time" bug).
public struct ActivityInstance: Hashable, Sendable {
    public var applicationID: ApplicationID
    /// The interaction that created it, which is also its instance number on
    /// the leave route and the frame's `launch_id`.
    public var launchID: String
    /// `i-{launch}-{location}`, the frame's `instance_id`. Nil where the wire
    /// left it out; `id.rawValue` spells the same thing.
    public var compositeInstanceID: String?
    public var location: ActivityLocation
    /// Everybody in it, in the order Discord lists them. Empty means it ended.
    public var participants: [ActivityParticipant]

    public init(
        applicationID: ApplicationID,
        launchID: String,
        compositeInstanceID: String? = nil,
        location: ActivityLocation,
        participants: [ActivityParticipant]
    ) {
        self.applicationID = applicationID
        self.launchID = launchID
        self.compositeInstanceID = compositeInstanceID
        self.location = location
        self.participants = participants
    }

    /// The instance as the leave route and the frame name it.
    public var id: ActivityInstanceID {
        ActivityInstanceID(instance: launchID, location: location)
    }

    /// What the frame's `instance_id` carries: Discord's own composite where it
    /// sent one (`compositeInstanceId ?? launchId`, module 51250).
    public var frameInstanceID: String { compositeInstanceID ?? id.rawValue }

    public var channelID: ChannelID { location.channelID }
    public var guildID: GuildID? { location.guildID }

    /// The people in it, once each (a person on two devices is two
    /// participants).
    public var userIDs: [UserID] {
        var seen = Set<UserID>()
        return participants.compactMap { seen.insert($0.userID).inserted ? $0.userID : nil }
    }

    public var isEmpty: Bool { participants.isEmpty }

    public func includes(_ userID: UserID) -> Bool {
        participants.contains { $0.userID == userID }
    }

    /// Whether this session, on this account, is one of the participants.
    ///
    /// **The session, not just the person.** The same account in Discord's own
    /// client is a participant too, and an instance it joined must not open a
    /// frame here (`EmbeddedActivitiesStore`: `user_id === me && session_id ===
    /// mine`).
    public func includes(_ userID: UserID, session sessionID: String) -> Bool {
        participants.contains { $0.userID == userID && $0.sessionID == sessionID }
    }

    /// This session's own participant record, which carries the launch's nonce.
    public func participant(_ userID: UserID, session sessionID: String) -> ActivityParticipant? {
        participants.first { $0.userID == userID && $0.sessionID == sessionID }
    }
}

/// One person, on one session, in an activity.
public struct ActivityParticipant: Hashable, Sendable {
    public var userID: UserID
    /// The gateway session they're in it from. Nil where the wire left it out.
    public var sessionID: String?
    /// The nonce of the launch or join that put this session in, where it was
    /// this session's own. It is how a launch knows which update answers it.
    public var nonce: String?

    public init(userID: UserID, sessionID: String? = nil, nonce: String? = nil) {
        self.userID = userID
        self.sessionID = sessionID
        self.nonce = nonce
    }
}
