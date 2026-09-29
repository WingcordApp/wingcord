import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GUILD_MEMBER_LIST_UPDATE`, decoded the way the socket decodes it.
///
/// The shape is the op-14 reply's: operations at absolute row positions, and
/// the list's groups beside them. **The groups are what this used to drop**, and
/// without them the list's size, its headings and its counts can only be
/// guessed from whoever the client happens to hold.
@Suite("Member list updates")
struct MemberListDecodeTests {

    private static let frame = """
    {"op":0,"s":42,"t":"GUILD_MEMBER_LIST_UPDATE","d":{
     "ops":[
      {"range":[0,99],"op":"SYNC","items":[
       {"group":{"id":"1043567046927487307","count":2}},
       {"member":{"user":{"id":"100","username":"ada","global_name":"Ada"},
        "roles":["1043567046927487307"],
        "presence":{"user":{"id":"100"},"status":"online","client_status":{"desktop":"online"},"activities":[]},
        "mute":false,"deaf":false,"joined_at":"2022-11-18T12:00:00.000000+00:00",
        "hoisted_role":"1043567046927487307","nick":null}},
       {"member":{"user":{"id":"101","username":"bo"},"roles":["1043567046927487307"],
        "joined_at":"2023-01-01T00:00:00.000000+00:00","nick":"Bo"}},
       {"group":{"id":"online","count":1}},
       {"member":{"user":{"id":"102","username":"cy"},"roles":[],
        "presence":{"user":{"id":"102"},"status":"idle","activities":[]},
        "joined_at":"2023-01-01T00:00:00.000000+00:00"}},
       {"member":{"roles":[]}}
      ]},
      {"op":"INVALIDATE","range":[100,199]},
      {"op":"DELETE","index":5},
      {"op":"INSERT","index":5,"item":{"group":{"id":"offline","count":247}}},
      {"op":"UPDATE","index":2,"item":{"member":{"user":{"id":"101","username":"bo"},"roles":[],"nick":"Bo"}}},
      {"op":"SOMETHING_NEW","index":1}
     ],
     "online_count":3,"member_count":250,"id":"everyone","guild_id":"1000",
     "groups":[{"id":"1043567046927487307","count":2},{"id":"online","count":1},{"id":"offline","count":247}]
    }}
    """

    private static func update() throws -> MemberListUpdate {
        let frame = try DiscordREST.decoder.decode(GatewayFrame.self, from: Data(frame.utf8))
        guard case .memberListUpdated(let update) = GatewayUpdate(frame.payload) else {
            Issue.record("not a member list update")
            throw CancellationError()
        }
        return update
    }

    @Test("The list, its groups and its counts survive")
    func groups() throws {
        let update = try Self.update()
        #expect(update.guildID == GuildID(rawValue: 1000))
        #expect(update.listID == "everyone")
        #expect(update.groups == [
            MemberList.Group(id: .role(RoleID(rawValue: 1_043_567_046_927_487_307)), count: 2),
            MemberList.Group(id: .online, count: 1),
            MemberList.Group(id: .offline, count: 247),
        ])
    }

    @Test("Every operation keeps its position, and an unknown one is skipped")
    func operations() throws {
        let update = try Self.update()
        let admins = MemberList.GroupID.role(RoleID(rawValue: 1_043_567_046_927_487_307))
        #expect(update.operations == [
            .sync(start: 0, rows: [
                .group(admins),
                .member(UserID(rawValue: 100)),
                .member(UserID(rawValue: 101)),
                .group(.online),
                .member(UserID(rawValue: 102)),
                // No user: a hole, not a dropped row that would shift the rest.
                nil,
            ]),
            .invalidate(100...199),
            .delete(5),
            .insert(5, .group(.offline)),
            .update(2, .member(UserID(rawValue: 101))),
        ])
    }

    @Test("The people it names reach the stores, offline when it says nothing")
    func people() throws {
        let update = try Self.update()
        // The later operation's record wins: the update took the role away.
        #expect(update.members[UserID(rawValue: 101)]?.nickname == "Bo")
        #expect(update.members[UserID(rawValue: 101)]?.roleIDs == [])
        #expect(update.users[UserID(rawValue: 100)]?.displayName == "Ada")
        #expect(update.presences[UserID(rawValue: 100)]?.status == .online)
        #expect(update.presences[UserID(rawValue: 102)]?.status == .idle)
        #expect(update.presences[UserID(rawValue: 101)]?.status == .offline)
    }
}
