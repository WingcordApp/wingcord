import Foundation
import WingcordCore

/// One `GUILD_MEMBER_LIST_UPDATE`: how one of a server's member lists changed,
/// and the people it names.
///
/// **The structure is the point.** This event used to be read as a bag of
/// members and nothing else, which threw away the only source of the list's
/// groups, their counts and where each row sits — so the roster was regrouped
/// from whoever the client held, and counted them. See `MemberList`.
public struct MemberListUpdate: Sendable {
    public var guildID: GuildID
    /// Which list this is — `MemberList.id(for:everyonePermissions:)` names the
    /// one a channel shows. Nil when the event did not say, and then only the
    /// people in it are kept: there is no list to put them in.
    public var listID: String?
    public var groups: [MemberList.Group]
    public var operations: [MemberList.Operation]
    /// Everyone the operations name, for the member, user and presence stores.
    public var members: [UserID: Member]
    public var users: [UserID: User]
    public var presences: [UserID: Presence]
}

extension MemberListUpdate {
    init(_ payload: MemberListUpdatePayload) {
        var members: [UserID: Member] = [:]
        var users: [UserID: User] = [:]
        var presences: [UserID: Presence] = [:]

        func row(_ item: MemberListUpdatePayload.Item?) -> MemberList.Row? {
            guard let item else { return nil }
            if let group = item.group {
                return .group(MemberList.GroupID(wire: group.id ?? ""))
            }
            guard let entry = item.member, let userDTO = entry.user else { return nil }
            users[userDTO.id] = userDTO.domain
            members[userDTO.id] = Member(
                userID: userDTO.id,
                nickname: entry.nick,
                avatarHash: entry.avatar,
                roleIDs: entry.roles ?? [],
                joinedAt: entry.joined_at,
                premiumSince: entry.premium_since
            )
            // The subscription answers with a presence for everyone it lists;
            // an entry without one is genuinely offline rather than unknown,
            // and defaulting it to unknown leaves the offline group empty.
            presences[userDTO.id] = entry.presence?.domain
                ?? Presence(userID: userDTO.id, status: .offline)
            return .member(userDTO.id)
        }

        var operations: [MemberList.Operation] = []
        for operation in payload.ops ?? [] {
            let range = operation.range.flatMap { bounds -> ClosedRange<Int>? in
                guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
                return bounds[0]...bounds[1]
            }
            switch operation.op {
            case "SYNC":
                guard let range else { continue }
                operations.append(.sync(
                    start: range.lowerBound,
                    rows: (operation.items ?? []).map(row)
                ))
            case "INVALIDATE":
                guard let range else { continue }
                operations.append(.invalidate(range))
            case "INSERT":
                guard let index = operation.index else { continue }
                operations.append(.insert(index, row(operation.item)))
            case "UPDATE":
                guard let index = operation.index else { continue }
                operations.append(.update(index, row(operation.item)))
            case "DELETE":
                guard let index = operation.index else { continue }
                operations.append(.delete(index))
            default:
                continue
            }
        }

        self.init(
            guildID: payload.guild_id,
            listID: payload.id,
            groups: (payload.groups ?? []).map { group in
                MemberList.Group(id: MemberList.GroupID(wire: group.id ?? ""), count: group.count ?? 0)
            },
            operations: operations,
            members: members,
            users: users,
            presences: presences
        )
    }
}
