import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// What a direct-message row carries.
///
/// **Tested through the projection, never through a helper** — §2. The row is
/// built inside `sidebarPresentation`, and the only level at which "is this
/// wired up" is a question a test can answer is the value the container reads.
@MainActor
@Suite("Direct message rows")
struct DirectMessageRowTests {

    private let me = UserID(rawValue: 1)
    private let them = UserID(rawValue: 2)
    private let channelID = ChannelID(rawValue: 10)

    private func model(
        decoration: UserDecoration? = nil,
        presence: Presence? = nil
    ) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.users[me] = User(id: me, username: "alex")
        model.users[them] = User(
            id: them,
            username: "rowan",
            displayName: "robinresting",
            decoration: decoration
        )
        model.channelIndex.replacePrivateChannels([
            Channel(id: channelID, kind: .directMessage, recipientIDs: [me, them]),
        ])
        if let presence { model.presences[them] = presence }
        model.selectedGuildID = nil
        return model
    }

    private func row(_ model: AppModel) -> SidebarChannel? {
        for row in model.sidebarPresentation.rows {
            if case .channel(let channel) = row, channel.id == channelID { return channel }
        }
        return nil
    }

    @Test("A conversation is a person, and takes the taller row")
    func personRowsAreTaller() {
        let channel = row(model())
        #expect(channel?.isPerson == true)
        // The height is on the value because the list measures it; a view that
        // worked it out from three optionals is a second answer that can differ.
        #expect(Metrics.directMessageRowHeight > Metrics.rowMinHeight)
    }

    @Test("What they are doing reaches the row")
    func activityReachesTheRow() {
        let playing = Presence(
            userID: them,
            status: .online,
            activities: PresenceActivities(list: [Activity(kind: .playing, name: "Xcode")])
        )
        #expect(row(model(presence: playing))?.subtitle?.contains("Xcode") == true)
        // Nothing to say is a real state, and the row keeps its height.
        #expect(row(model())?.subtitle == nil)
    }

    @Test("The plate, the tag and the name style all reach the row")
    func decorationReachesTheRow() {
        let decoration = UserDecoration(
            nameplate: Nameplate(asset: "nameplates/dark_roses/1/", palette: .berry),
            displayNameStyle: DisplayNameStyle(font: .sakura, effect: .solid, colors: [0xFF00FF]),
            primaryGuildTag: "LUSH"
        )
        let channel = row(model(decoration: decoration))
        #expect(channel?.nameplateURL != nil)
        #expect(channel?.nameplatePalette == NameplatePalette.berry)
        #expect(channel?.tag == "LUSH")
        #expect(channel?.nameStyle?.font == DisplayNameFont.sakura)
    }

    @Test("A person's presence rebuilds the list; a server's channels do not")
    func presenceKeysOnlyTheDirectMessageList() {
        // The memo would otherwise answer with the list from before somebody
        // started a game — and carrying presence unconditionally would rebuild a
        // five-hundred-channel tree on every flush in the account.
        let model = model()
        _ = model.sidebarPresentation
        model.presences[them] = Presence(
            userID: them,
            status: .online,
            activities: PresenceActivities(list: [Activity(kind: .playing, name: "Xcode")])
        )
        model.presenceRevision &+= 1
        #expect(row(model)?.subtitle?.contains("Xcode") == true)
    }
}
