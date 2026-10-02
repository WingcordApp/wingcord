import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The two profiles a person has, and the one the card is showing.
///
/// **Discord's profile menu offers both** — "View Main Profile" and "View
/// Per-server Profile" — which is only possible if both are kept. This client
/// used to fold the guild layer onto the account layer at decode time, so the
/// account's own banner, bio, colours and effect were destroyed the moment a
/// server override existed. The card that resulted was neither profile: the
/// server's roles under the account's name.
@MainActor
@Suite("Per-server profiles")
struct PerServerProfileTests {

    private let readerID = UserID(rawValue: 1)
    private let friendID = UserID(rawValue: 2)
    private let guildID = GuildID(rawValue: 10)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [
            readerID: User(id: readerID, username: "reader"),
            friendID: User(
                id: friendID,
                username: "corvin_",
                displayName: "Corvin",
                decoration: UserDecoration(bio: "the account's own words")
            ),
        ]
        model.guilds = [guildID: Guild(id: guildID, name: "server", ownerID: readerID)]
        model.members = [guildID: [
            friendID: Member(userID: friendID, nickname: "Corvin KQZRA-TMWB", roleIDs: []),
        ]]
        // What `GET /users/{id}/profile?guild_id=…` answered with, kept beside
        // the account's rather than folded into it.
        model.memberProfiles = [guildID: [
            friendID: User(
                id: friendID,
                username: "corvin_",
                displayName: "Corvin",
                decoration: UserDecoration(bio: "what they say in this server")
            ),
        ]]
        return model
    }

    private func request(showsMain: Bool) -> ProfileRequest {
        ProfileRequest(
            userID: friendID,
            guildID: guildID,
            showsMainProfile: showsMain,
            anchor: .zero
        )
    }

    @Test("A per-server profile is named by the nickname and wears the server's bio")
    func perServerProfile() throws {
        let profile = try #require(
            model().profilePresentation(for: request(showsMain: false))
        )
        #expect(profile.displayName == "Corvin KQZRA-TMWB")
        #expect(profile.bio == "what they say in this server")
        #expect(!profile.showsMainProfile)
        // And it offers the other one, by the name the other one uses.
        #expect(profile.alternateName == "Corvin")
    }

    @Test("The main profile is the account's own, with none of the server on it")
    func mainProfile() throws {
        let profile = try #require(
            model().profilePresentation(for: request(showsMain: true))
        )
        #expect(profile.displayName == "Corvin")
        #expect(profile.bio == "the account's own words")
        #expect(profile.showsMainProfile)
        // **No roles and no join date.** Those belong to the membership, and a
        // main profile carrying them is the hybrid this replaced.
        #expect(profile.roles.isEmpty)
        #expect(profile.memberSince == nil)
        #expect(profile.alternateName == "Corvin KQZRA-TMWB")
    }

    @Test("Switching keeps the anchor and the depth")
    func switchingKeepsTheRequest() {
        let model = model()
        let anchor = CGRect(x: 12, y: 34, width: 56, height: 78)
        model.profileRequest = ProfileRequest(
            userID: friendID, guildID: guildID, anchor: anchor, depth: .full
        )
        model.showMainProfile(true)
        // A rebuilt request would reopen the card somewhere else, at the wrong
        // depth — which is what makes this an edit rather than a new request.
        #expect(model.profileRequest?.showsMainProfile == true)
        #expect(model.profileRequest?.anchor == anchor)
        #expect(model.profileRequest?.depth == .full)
        #expect(model.profileRequest?.guildID == guildID)
    }

    @Test("A server that adds nothing offers no switch")
    func noAlternateWithoutALayer() throws {
        let model = model()
        model.memberProfiles = [:]
        model.members = [guildID: [friendID: Member(userID: friendID, roleIDs: [])]]
        let profile = try #require(
            model.profilePresentation(for: request(showsMain: false))
        )
        // No nickname and no per-server layer: both profiles read the same, and
        // an item offering to show you the one you are looking at is noise.
        #expect(profile.alternateName == nil)
    }

    @Test("Raising the card to the full profile keeps its subject")
    func expandProfile() {
        let model = model()
        model.profileRequest = ProfileRequest(userID: friendID, guildID: guildID, anchor: .zero)
        model.expandProfile()
        #expect(model.profileRequest?.depth == .full)
        #expect(model.profileRequest?.userID == friendID)
    }
}
