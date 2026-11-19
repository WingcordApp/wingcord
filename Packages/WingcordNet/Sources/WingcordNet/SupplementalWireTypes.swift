import Foundation
import WingcordCore

// MARK: - The half of the bootstrap that arrives second
//
// **This client asks for a split READY and had never read the second half.**
// `capabilities` carries `PRIORITIZED_READY_PAYLOAD` (1 << 5), and the effect of
// that bit is documented on the gateway guild object in one line: `voice_states`
// is *omitted* from every guild in READY and sent afterwards in
// `READY_SUPPLEMENTAL` instead. So every voice channel in the app opened empty —
// not because the sidebar could not draw people, but because the account's own
// bootstrap had told it there were none, and nothing ever corrected that until
// somebody moved.
//
// The same bit moves two more things out of READY: the guilds' members, into
// `merged_members`, and their presences, into `merged_presences`. Both are
// **positional** — index `i` of each is guild `i` of *READY's* guild array —
// which is why this decode takes that order as a parameter and guards on its
// count. Getting it wrong files one server's nicknames under another, silently.
//
// `DEDUPE_USER_OBJECTS` (1 << 4) is set beside it, which is why the members and
// presences in here name their person with `user_id` rather than carrying a
// user object. See `MemberDTO.user_id`.

/// `READY_SUPPLEMENTAL`.
struct ReadySupplementalPayload: Decodable, Sendable {
    var guilds: [SupplementalGuildDTO]?
    /// One array per guild, in `guilds` order. For a user account these are the
    /// people READY could not send: the reader's own member record, and
    /// **everybody sitting in a voice channel** — which is exactly the set the
    /// sidebar needs a name and a face for.
    var merged_members: [[MemberDTO]]?
    var merged_presences: MergedPresencesDTO?
    /// Conversations Discord left out of READY because the client was expected
    /// to have them cached. This client caches nothing across sessions, so
    /// leaving them out would be a DM list missing rows.
    var lazy_private_channels: [ChannelDTO]?
}

/// One guild in `READY_SUPPLEMENTAL`. An unavailable guild carries only `id`.
struct SupplementalGuildDTO: Decodable, Sendable {
    var id: GuildID?
    var voice_states: [VoiceStateDTO]?
    /// The activities running in this server's channels. Discord's store is
    /// rebuilt from these on every connection (`CONNECTION_OPEN_SUPPLEMENTAL`).
    var activity_instances: LossyList<ActivityInstanceDTO>?
}

struct MergedPresencesDTO: Decodable, Sendable {
    /// Friends and implicit relationships, wherever they are.
    var friends: [PresenceDTO]?
    /// One array per guild, in `guilds` order.
    var guilds: [[PresenceDTO]]?
}

/// Everything the second half of the bootstrap said.
public struct ReadySupplementalSnapshot: Sendable {
    /// Who is in a voice channel, keyed by the person — the same flat shape
    /// `ReadySnapshot` uses, and for the same reason: a person is in at most one
    /// voice channel across the whole account.
    public var voiceStates: [UserID: VoiceState]
    /// The members that came with them, so a face in a voice row has a nickname
    /// and a server avatar rather than a raw user id.
    public var membersByGuild: [GuildID: [UserID: Member]]
    /// Friends' presences and the guild presences READY held back. **Merged into
    /// what the store already has rather than replacing it** — see
    /// `SessionController.applyReadySupplemental`.
    public var presences: [UserID: Presence]
    public var privateChannels: [Channel]
    /// Every server's running activities, keyed by server. A server listed
    /// with none is in here with an empty array: it is the whole truth for it.
    public var activityInstances: [GuildID: [ActivityInstance]]

    /// - Parameter guildOrder: the order READY listed the account's guilds in.
    ///   **The merged arrays are indexed against *that* list**, not against this
    ///   payload's — the two are the same servers in the same order in every
    ///   capture, but the documentation names READY's and an assumption written
    ///   into a decoder is an assumption nobody re-checks. Empty falls back to
    ///   this payload's own order, which is what a resumed session has.
    init(payload: ReadySupplementalPayload, guildOrder: [GuildID] = []) {
        let guilds = payload.guilds ?? []
        var voiceStates: [UserID: VoiceState] = [:]
        var membersByGuild: [GuildID: [UserID: Member]] = [:]
        var presences: [UserID: Presence] = [:]

        // **Positional, and guarded on the count.** The two merged arrays are
        // documented as parallel to `guilds`; a payload where they are not is a
        // payload whose members would be filed under the wrong servers, which is
        // worse than having none. A mismatch drops the parallel arrays and keeps
        // the voice states, which are self-describing.
        let order = guildOrder.isEmpty ? guilds.compactMap(\.id) : guildOrder
        let members = payload.merged_members
        let guildPresences = payload.merged_presences?.guilds
        let membersAlign = members?.count == order.count
        let presencesAlign = guildPresences?.count == order.count
        // Said once, because a mismatch drops every server's own record — and
        // a server whose channels all deny `@everyone` then shows nothing.
        if let members, !membersAlign {
            Log.fault(.gateway, "READY_SUPPLEMENTAL: merged members for \(members.count) servers, READY named \(order.count); dropped")
        }

        // The merged arrays are walked against READY's order; the voice states
        // are walked against this payload's own guilds, which name themselves.
        if membersAlign || presencesAlign {
            for (offset, guildID) in order.enumerated() {
                if membersAlign, let list = members?[offset], !list.isEmpty {
                    var table = membersByGuild[guildID] ?? [:]
                    table.reserveCapacity(table.count + list.count)
                    for memberDTO in list {
                        guard let userID = memberDTO.user?.id ?? memberDTO.user_id else { continue }
                        table[userID] = memberDTO.domain(userID: userID)
                    }
                    membersByGuild[guildID] = table
                }
                if presencesAlign, let list = guildPresences?[offset] {
                    for presenceDTO in list {
                        guard let presence = presenceDTO.domain else { continue }
                        presences[presence.userID] = presence
                    }
                }
            }
        }

        for guildDTO in guilds {
            guard let guildID = guildDTO.id, let states = guildDTO.voice_states, !states.isEmpty
            else { continue }

            for stateDTO in states {
                guard var state = stateDTO.domain, state.channelID != nil else { continue }
                // These are nested in their guild and say so nowhere else —
                // the same omission READY's own per-guild states have, and the
                // same fix: without it every one of them looks like a
                // direct-message call.
                state.guildID = state.guildID ?? guildID
                voiceStates[state.userID] = state
                // A state may carry its member inline, and where it does that
                // copy is the freshest there is — so it is written *after*
                // `merged_members` rather than being skipped as a duplicate.
                if let memberDTO = stateDTO.member {
                    membersByGuild[guildID, default: [:]][state.userID] =
                        memberDTO.domain(userID: state.userID)
                }
            }
        }

        for presenceDTO in payload.merged_presences?.friends ?? [] {
            guard let presence = presenceDTO.domain else { continue }
            presences[presence.userID] = presence
        }

        // The running activities, and the members their participants carried
        // (a face in an activity tile needs a name like a face in a voice row).
        var instances: [GuildID: [ActivityInstance]] = [:]
        for guildDTO in guilds {
            guard let guildID = guildDTO.id else { continue }
            instances[guildID] = (guildDTO.activity_instances?.elements ?? []).compactMap(\.domain)
            for dto in guildDTO.activity_instances?.elements ?? [] {
                for (userID, member) in dto.members {
                    membersByGuild[guildID, default: [:]][userID] = member
                }
            }
        }

        self.voiceStates = voiceStates
        self.membersByGuild = membersByGuild
        self.presences = presences
        self.privateChannels = (payload.lazy_private_channels ?? []).map { $0.domain() }
        self.activityInstances = instances
    }
}

// MARK: - The guilds nobody is looking at

/// `PASSIVE_UPDATE_V2`.
///
/// **The other half of the same trade.** `PASSIVE_GUILD_UPDATE_V2` (1 << 14) is
/// also in this client's capability word, and what that bit buys is silence:
/// Discord stops sending `VOICE_STATE_UPDATE` and `CHANNEL_UNREAD_UPDATE` for
/// every guild the client is not subscribed to, and sends this instead — a
/// periodic delta for one guild at a time. A client that enables the bit and
/// does not read the event has asked to be told nothing about eighty-nine of its
/// ninety servers.
struct PassiveUpdateDTO: Decodable, Sendable {
    var guild_id: GuildID
    /// Unreads. `last_message_id` is what makes a rail tile light up.
    var updated_channels: [ChannelUnreadDTO]?
    var updated_voice_states: [VoiceStateDTO]?
    /// **Ids, not states.** A departure in this event is a bare user id in this
    /// array rather than a state with a null channel, which is the one place
    /// Discord's two ways of saying "they left" differ.
    var removed_voice_states: [UserID]?
    /// The people behind `updated_voice_states`, and nobody else.
    var updated_members: [MemberDTO]?
}

struct ChannelUnreadDTO: Decodable, Sendable {
    var id: ChannelID
    var last_message_id: MessageID?
}

// MARK: - What a voice channel says about itself

/// `VOICE_CHANNEL_STATUS_UPDATE` — the line anybody in the room can set.
struct VoiceChannelStatusDTO: Decodable, Sendable {
    /// **The channel, and it is `id` rather than `channel_id`.** This event
    /// names its subject the way a channel object does, not the way every other
    /// voice event does.
    var id: ChannelID
    var guild_id: GuildID?
    var status: String?
}

/// `VOICE_CHANNEL_START_TIME_UPDATE` — when the room's current session began.
struct VoiceChannelStartTimeDTO: Decodable, Sendable {
    var id: ChannelID
    var guild_id: GuildID?
    /// Null is the session **ending**, not an absence.
    var voice_start_time: VoiceStartTime?
}

/// `CHANNEL_INFO`, the answer to opcode 43.
struct ChannelInfoPayload: Decodable, Sendable {
    var guild_id: GuildID
    var channels: [ChannelMetadataDTO]?
}

/// One channel's extra voice fields.
struct ChannelMetadataDTO: Decodable, Sendable {
    var id: ChannelID
    var status: String?
    var voice_start_time: VoiceStartTime?
}

/// When a voice session started, in **either** of the two shapes the wire uses.
///
/// **The documentation contradicts itself here and the decoder does not get to
/// pick.** `CHANNEL_INFO` types the field as an ISO-8601 timestamp and then
/// describes it as a unix timestamp in seconds; the update event types it as an
/// integer. A decoder that assumes one throws away every payload that sends the
/// other — and a throw on this path costs the whole frame it arrived in, not
/// just the timer.
struct VoiceStartTime: Decodable, Sendable {
    var date: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            date = nil
        } else if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
        } else if let text = try? container.decode(String.self) {
            date = ISO8601DateFormatter.withFraction.date(from: text)
                ?? ISO8601DateFormatter.plain.date(from: text)
        } else {
            date = nil
        }
    }
}
