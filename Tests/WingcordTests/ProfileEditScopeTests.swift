import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Which profile the editor is changing, and what it starts from.
///
/// **The seeding defect is the one to guard.** Opened from a server, the sheet
/// shows the per-server profile; an editor that seeded "Main Profile" from it
/// put the reader's nickname and server bio into the fields that write their
/// account — one Save from replacing a global name with a server nickname.
@MainActor
@Suite("Profile edit scopes")
struct ProfileEditScopeTests {

    private let me = UserID(rawValue: 1)
    private let alpha = GuildID(rawValue: 10)
    private let beta = GuildID(rawValue: 20)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.users = [
            me: User(
                id: me, username: "alexsample", displayName: "alex",
                decoration: UserDecoration(bio: "my account bio")
            ),
        ]
        model.guilds = [
            alpha: Guild(id: alpha, name: "Alpha", ownerID: me),
            beta: Guild(id: beta, name: "Beta", ownerID: me),
        ]
        model.members = [
            alpha: [me: Member(userID: me, nickname: "test", roleIDs: [])],
            beta: [me: Member(userID: me, roleIDs: [])],
        ]
        model.memberProfiles = [alpha: [
            me: User(
                id: me, username: "alexsample", displayName: "alex",
                decoration: UserDecoration(bio: "my alpha bio")
            ),
        ]]
        // The rail puts Beta first; the switcher must follow the rail.
        model.folders = [GuildFolder(guildIDs: [beta, alpha])]
        // The sheet is open inside Alpha.
        model.selectedGuildID = alpha
        return model
    }

    @Test("Main Profile is seeded from the account, not from the server it was opened in")
    func accountBaseIgnoresTheServer() throws {
        let base = try #require(model().profileEditBase(for: .account, userID: me))
        #expect(base.displayName == "alex")
        #expect(base.bio == "my account bio")
        #expect(base.roles.isEmpty)
    }

    @Test("A server scope is seeded from that server's layer and nickname")
    func guildBaseUsesTheLayer() throws {
        let base = try #require(model().profileEditBase(for: .guild(alpha), userID: me))
        #expect(base.displayName == "test")
        #expect(base.bio == "my alpha bio")
    }

    @Test("Main first, then every server in the rail's order, with the nickname under it")
    func scopesFollowTheRail() {
        let scopes = model().profileEditScopes(for: me)
        #expect(scopes.map(\.title) == ["Main Profile", "Beta", "Alpha"])
        #expect(scopes[2].subtitle == "test")
        // No nickname, one line.
        #expect(scopes[1].subtitle == nil)
    }

    @Test("In a server the name field is the nickname, and cleared it falls back")
    func guildPreviewFollowsTheNickname() throws {
        let model = model()
        let base = try #require(model.profileEditBase(for: .guild(alpha), userID: me))
        let editor = ProfileEditor(
            profile: base, widgets: [], scope: .guild(alpha), accountName: "alex"
        )
        editor.nickname = "renamed"
        #expect(editor.applied(to: editor.base).displayName == "renamed")
        // Discord shows the account's own name for a member with no nickname.
        editor.nickname = ""
        #expect(editor.applied(to: editor.base).displayName == "alex")
    }
}
