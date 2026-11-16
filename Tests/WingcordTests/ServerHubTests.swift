import Foundation
import SwiftUI
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The Server Hub in the app: who is offered it, what editing does, and what
/// the page is told to draw (docs/BETA2.md, phase 9).
@MainActor
@Suite("Server Hub")
struct ServerHubTests {

    private let guildID = GuildID(rawValue: 77)
    private let me = UserID(rawValue: 7)

    private func model(isOwner: Bool, settings: GuildSpaceSettings?) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        var guild = Guild(id: guildID, name: "Hub Test", ownerID: isOwner ? me : UserID(rawValue: 99))
        guild.spaceSettings = settings
        model.guilds[guildID] = guild
        model.selectedGuildID = guildID
        return model
    }

    private func widget(_ id: String, _ kind: GuildSpaceWidgetKind = .imageText, column: Int, order: Int) -> GuildSpaceWidget {
        GuildSpaceWidget(id: id, kind: kind, position: .init(column: column, order: order))
    }

    @Test("Offered only with the switch on, and as Discord's rule says")
    func offering() async {
        await withAppSettings(\.showsServerHub) { settings in
            let published = GuildSpaceSettings(isEnabled: true, publishStatus: .published)
            let draft = GuildSpaceSettings(isEnabled: true, publishStatus: .draft)

            settings.showsServerHub = false
            #expect(!model(isOwner: false, settings: published).offersServerHub(guildID))

            settings.showsServerHub = true
            #expect(model(isOwner: false, settings: published).offersServerHub(guildID))
            #expect(!model(isOwner: false, settings: draft).offersServerHub(guildID))
            #expect(model(isOwner: true, settings: draft).offersServerHub(guildID))
            // Never turned on here for a server Discord hasn't given one.
            #expect(!model(isOwner: true, settings: nil).offersServerHub(guildID))

            // Discord answered that there's none: only an editor may make one.
            let member = model(isOwner: false, settings: published)
            member.serverHub.missing.insert(guildID)
            #expect(!member.offersServerHub(guildID))
            let owner = model(isOwner: true, settings: published)
            owner.serverHub.missing.insert(guildID)
            #expect(owner.offersServerHub(guildID))
        }
    }

    @Test("A drop moves the card to the column and the place it landed")
    func reorder() {
        let model = model(isOwner: true, settings: .init(isEnabled: true, publishStatus: .published))
        model.serverHub.spaces[guildID] = GuildSpace(guildID: guildID, widgets: [
            widget("a", column: 0, order: 0), widget("b", column: 0, order: 1), widget("c", column: 1, order: 0),
        ])
        model.beginServerHubEdit()
        model.dropServerHubWidget("a", inColumn: 1, before: "c")
        let columns = GuildSpaceLayout.columns(model.serverHub.draft?.widgets ?? [])
        #expect(columns[0].map(\.id) == ["b"])
        #expect(columns[1].map(\.id) == ["a", "c"])
        model.dropServerHubWidget("c", inColumn: 0, before: nil)
        #expect(GuildSpaceLayout.columns(model.serverHub.draft?.widgets ?? [])[0].map(\.id) == ["b", "c"])
    }

    @Test("A failed save's message goes the moment the edit changes")
    func failureClears() {
        let model = model(isOwner: true, settings: .init(isEnabled: true, publishStatus: .published))
        model.serverHub.spaces[guildID] = GuildSpace(guildID: guildID, widgets: [widget("a", column: 0, order: 0)])
        model.beginServerHubEdit()
        model.serverHub.draft?.saveState = .failed("Nope")
        model.removeServerHubWidget("a")
        #expect(model.serverHub.draft?.saveState == .idle)
        #expect(model.serverHub.draft?.hasChanges == true)
    }

    @Test("A hub Discord doesn't have yet starts from Discord's own first layout")
    func newHub() {
        let model = model(isOwner: true, settings: .init(isEnabled: true, publishStatus: .draft))
        model.serverHub.missing.insert(guildID)
        model.beginServerHubEdit()
        let draft = model.serverHub.draft
        #expect(draft?.isNewHub == true)
        #expect(draft.map { GuildSpaceLayout.columns($0.widgets).map { $0.map(\.kind) } } == [[.leaderboard, .whiteboard], [.popularGames]])
    }

    @Test("A leaderboard reads its values, its days left and the reader's place")
    func leaderboardPresentation() {
        let model = model(isOwner: false, settings: .init(isEnabled: true, publishStatus: .published))
        let board = GuildSpaceLeaderboard(
            stat: .hoursPlayed,
            nextStat: .daysPlayed,
            weekStart: Date.now.addingTimeInterval(-6.2 * 86_400),
            entries: (1...4).map { GuildSpaceLeaderboard.Entry(userID: UserID(rawValue: UInt64(100 + $0)), rank: $0, value: 3_600_000 * Double(10 - $0)) }
        )
        model.serverHub.spaces[guildID] = GuildSpace(guildID: guildID, widgets: [
            GuildSpaceWidget(id: "lb", kind: .leaderboard, position: .init(column: 1, order: 0), requiresHydration: true),
        ])
        model.serverHub.hydrations["lb"] = .loaded(.leaderboard(board))
        model.users[me] = User(id: me, username: "me", displayName: "Me", discriminator: "0")

        let item = model.serverHubPresentation?.columns[1].first
        #expect(item?.title == "Most Game Time")
        #expect(item?.accessory == "1d left")
        guard case .leaderboard(let card) = item?.content else {
            Issue.record("expected a leaderboard")
            return
        }
        #expect(card.rows.first?.value == "9h")
        #expect(card.unranked != nil)
        #expect(item?.expansion == .leaderboard(widgetID: "lb"))
    }
}
