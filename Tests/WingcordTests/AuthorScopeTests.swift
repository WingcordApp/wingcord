import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Which server an author is resolved against.
///
/// **The answer is the channel the messages are IN, never the one the rail is
/// pointing at.** In the main window the two are the same by construction — a
/// direct message is only open at Home — and three surfaces broke that: the
/// overlay's chat window (a conversation open while a server is selected), the
/// inbox and the search pane (both list messages from servers other than the
/// open one). The overlay is what made it visible, because a DM there wore the
/// selected server's role colour on every name.
@MainActor
@Suite("Author scope")
struct AuthorScopeTests {

    private let readerID = UserID(rawValue: 1)
    private let friendID = UserID(rawValue: 2)
    private let guildID = GuildID(rawValue: 10)
    private let roleID = RoleID(rawValue: 11)
    private let guildChannel = ChannelID(rawValue: 20)
    private let dm = ChannelID(rawValue: 30)

    /// One server where the friend wears a red role and a nickname, and one
    /// conversation with the same person where they wear neither.
    ///
    /// - Parameter nameStyle: the effect and colours the friend chose, for the
    ///   two tests about what survives the trip from the user record.
    private func model(nameStyle: DisplayNameStyle? = nil) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [
            readerID: User(id: readerID, username: "reader"),
            friendID: User(
                id: friendID,
                username: "friend",
                displayName: "Friend",
                decoration: nameStyle.map { UserDecoration(displayNameStyle: $0) }
            ),
        ]
        model.guilds = [guildID: Guild(id: guildID, name: "server", ownerID: readerID)]
        model.roles = [guildID: [
            roleID: Role(id: roleID, name: "Red", colorValue: 0xFF_00_00, position: 5),
        ]]
        model.members = [guildID: [
            friendID: Member(userID: friendID, nickname: "Nickname", roleIDs: [roleID]),
        ]]

        var index = ChannelIndex()
        index.replaceChannels(
            [Channel(id: guildChannel, kind: .text, guildID: guildID, name: "general")],
            inGuild: guildID
        )
        index.replacePrivateChannels([
            Channel(id: dm, kind: .directMessage, name: "", recipientIDs: [friendID]),
        ])
        model.channelIndex = index
        // The rail is pointing at the server — which is the whole of the trap.
        model.selectedGuildID = guildID
        model.selectedChannelID = guildChannel
        return model
    }

    private var items: [TimelineItem] {
        [.message(TimelineMessage(
            message: Message(
                id: MessageID(rawValue: 100), channelID: dm, authorID: friendID,
                content: "hey"
            ),
            flags: [.head, .tail]
        ))]
    }

    private var font: NSFont { PresentationRevision.shared.style.authorFont }

    @Test("A conversation's author wears no server's colour, whatever is selected")
    func directMessagesAreUnscoped() throws {
        let authors = model().authorInfo(for: items, inGuild: nil, authorFont: font)
        let friend = try #require(authors[friendID])
        #expect(friend.colorValue == nil)
        // …and the name they chose, not the server's nickname for them.
        #expect(friend.name == "Friend")
    }

    @Test("A server's author still wears that server's colour and nickname")
    func guildMessagesAreScoped() throws {
        let authors = model().authorInfo(for: items, inGuild: guildID, authorFont: font)
        let friend = try #require(authors[friendID])
        #expect(friend.colorValue != nil)
        #expect(friend.name == "Nickname")
    }

    @Test("A conversation carries the name style its owner chose")
    func directMessagesCarryTheNameStyle() throws {
        // **`display_name_styles` rides the ordinary user object**, not the
        // guild member — so it is present for somebody you have never shared a
        // server with, which is exactly the case this feature is for. It had
        // been decoded and then dropped here for every session before this one:
        // only `.font` was read, and the effect and colours went nowhere.
        let prism = DisplayNameStyle(
            font: .default, effect: .prism, colors: [0xE9_1E_63, 0x21_96_F3]
        )
        let authors = model(nameStyle: prism)
            .authorInfo(for: items, inGuild: nil, authorFont: font)
        let friend = try #require(authors[friendID])
        #expect(friend.nameStyle == prism)
    }

    @Test("A styled face with no colours is not carried as an effect")
    func faceWithoutColoursIsNotAnEffect() throws {
        // Nearly every styled account is this one. The face already reaches the
        // transcript through `nameFace`; carrying the rest would put a glyph run
        // and a clip behind a name that is a flat label either way.
        let faceOnly = DisplayNameStyle(font: .sakura, effect: .solid, colors: [])
        let authors = model(nameStyle: faceOnly)
            .authorInfo(for: items, inGuild: nil, authorFont: font)
        let friend = try #require(authors[friendID])
        #expect(friend.nameStyle == nil)
        #expect(friend.nameFace != nil)
    }
}
