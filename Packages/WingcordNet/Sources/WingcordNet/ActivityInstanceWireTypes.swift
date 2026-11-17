import Foundation
import WingcordCore

// MARK: - Running activities on the wire
//
// `EMBEDDED_ACTIVITY_UPDATE_V2`, and the `activity_instances` array that
// READY_SUPPLEMENTAL's guilds and GUILD_CREATE carry. Discord's gateway handler
// reads exactly these fields (`{application_id, launch_id,
// composite_instance_id, location, participants, content_classification}`,
// web.js) and its store keys everything on them (module 933958).

/// One running activity.
///
/// **Every field optional.** The dispatch has no published schema, and one
/// instance this client can't read must not cost the reader every other one in
/// a server.
struct ActivityInstanceDTO: Decodable, Sendable {
    var application_id: ApplicationID?
    var launch_id: String?
    var composite_instance_id: String?
    var location: LocationDTO?
    var participants: [ParticipantDTO]?
    /// Top level on the V2 dispatch, beside `location.guild_id`.
    var guild_id: GuildID?

    struct LocationDTO: Decodable, Sendable {
        /// `gc-{guild}-{channel}` or `pc-{channel}`.
        var id: String?
        var kind: String?
        var channel_id: ChannelID?
        var guild_id: GuildID?
    }

    struct ParticipantDTO: Decodable, Sendable {
        var user_id: UserID?
        var session_id: String?
        /// The launch's or join's nonce, on the session that sent it.
        var nonce: String?
        /// Present in a server's instances, so a face in the tile has a name.
        var member: MemberDTO?
    }

    /// The instance, or nil where the wire didn't say which app or where.
    var domain: ActivityInstance? {
        guard let applicationID = application_id, let launchID = launch_id, !launchID.isEmpty,
              let location = resolvedLocation
        else { return nil }
        let participants = (self.participants ?? []).compactMap { dto -> ActivityParticipant? in
            guard let userID = dto.user_id else { return nil }
            return ActivityParticipant(userID: userID, sessionID: dto.session_id, nonce: dto.nonce)
        }
        return ActivityInstance(
            applicationID: applicationID,
            launchID: launchID,
            compositeInstanceID: composite_instance_id,
            location: location,
            participants: participants
        )
    }

    /// The location's own id first, its fields second: the id is what every
    /// route and the frame are spelled with.
    private var resolvedLocation: ActivityLocation? {
        if let id = location?.id, let parsed = ActivityLocation(rawValue: id) { return parsed }
        guard let channelID = location?.channel_id else { return nil }
        return ActivityLocation(guildID: location?.guild_id ?? guild_id, channelID: channelID)
    }

    /// The members its participants carried, for a server's instance.
    var members: [UserID: Member] {
        var members: [UserID: Member] = [:]
        for participant in participants ?? [] {
            guard let userID = participant.user_id, let member = participant.member else { continue }
            members[userID] = member.domain(userID: userID)
        }
        return members
    }
}
