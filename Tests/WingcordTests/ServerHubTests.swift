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

    /// The server put in Discord's `2026-09-guild-spaces` experiment, at
    /// `variant` (0 is "off").
    private func inExperiment(_ model: AppModel, variant: Int) -> AppModel {
        let hash = MurmurHash3.hash32(AppModel.serverHubExperiment)
        let eligible = [hash: ApexAssignment(hash: hash, variantID: 0, isOverride: false, revision: 1, usesAsEligibility: true)]
        model.experiments = ExperimentSnapshot(apexReader: eligible)
        model.guilds[guildID]?.apexAssignments = [
            hash: ApexAssignment(hash: hash, variantID: variant, isOverride: false, revision: 3),
        ]
        return model
    }

    /// **Discord's channel list needs both**: hub settings, and the server in
    /// the experiment (docs/ACTIVITIES-CALLS-PICKER.md, decision 23). Alex's
    /// account had 18 servers with published settings and 3 in the experiment;
    /// the other 15 answered "Unknown Guild Space".
    @Test("Offered only with the switch on, and only where Discord shows it")
    func offering() async {
        await withAppSettings(\.showsServerHub) { settings in
            let published = GuildSpaceSettings(isEnabled: true, publishStatus: .published)
            let draft = GuildSpaceSettings(isEnabled: true, publishStatus: .draft)

            settings.showsServerHub = false
            #expect(!inExperiment(model(isOwner: false, settings: published), variant: 1).offersServerHub(guildID))

            settings.showsServerHub = true
            #expect(inExperiment(model(isOwner: false, settings: published), variant: 1).offersServerHub(guildID))
            #expect(!inExperiment(model(isOwner: false, settings: draft), variant: 1).offersServerHub(guildID))
            #expect(inExperiment(model(isOwner: true, settings: draft), variant: 1).offersServerHub(guildID))

            // Discord answered that there's none: only an editor may make one.
            let member = inExperiment(model(isOwner: false, settings: published), variant: 1)
            member.serverHub.missing.insert(guildID)
            #expect(!member.offersServerHub(guildID))
            let owner = inExperiment(model(isOwner: true, settings: published), variant: 1)
            owner.serverHub.missing.insert(guildID)
            #expect(owner.offersServerHub(guildID))

            // No experiment data at all: nothing is guessed from the settings;
            // a hub is offered once it has actually loaded with cards.
            let unknown = model(isOwner: false, settings: published)
            #expect(!unknown.offersServerHub(guildID))
            unknown.serverHub.spaces[guildID] = GuildSpace(guildID: guildID, widgets: [
                widget("a", column: 0, order: 0),
            ])
            #expect(unknown.offersServerHub(guildID))
            #expect(!model(isOwner: true, settings: nil).offersServerHub(guildID))
        }
    }

    @Test("Discord's experiment offers an editor the row to make a hub, and outside it there is none")
    func experimentOffering() async {
        await withAppSettings(\.showsServerHub) { settings in
            settings.showsServerHub = true

            // No hub yet, in a server Discord has put in the experiment.
            #expect(inExperiment(model(isOwner: true, settings: nil), variant: 1).offersServerHub(guildID))
            #expect(inExperiment(model(isOwner: true, settings: nil), variant: 1).mayHaveServerHub(guildID))
            // Only its editors: the others have nothing to see until it's published.
            #expect(!inExperiment(model(isOwner: false, settings: nil), variant: 1).offersServerHub(guildID))
            // Variant 0 is "off", and with no experiment data at all nothing is guessed.
            #expect(!inExperiment(model(isOwner: true, settings: nil), variant: 0).offersServerHub(guildID))
            #expect(model(isOwner: true, settings: nil).isInServerHubExperiment(Guild(id: guildID, name: "x", ownerID: me)) == nil)
            // **Published settings outside the experiment are not a hub**: Discord
            // shows none there and its route answers 404. Not offered, not asked.
            let published = GuildSpaceSettings(isEnabled: true, publishStatus: .published)
            #expect(!inExperiment(model(isOwner: false, settings: published), variant: 0).offersServerHub(guildID))
            #expect(!inExperiment(model(isOwner: false, settings: published), variant: 0).mayHaveServerHub(guildID))
            // Switched off by the server, nobody gets it.
            let off = GuildSpaceSettings(isEnabled: false, publishStatus: .published)
            #expect(!inExperiment(model(isOwner: true, settings: off), variant: 1).offersServerHub(guildID))
        }
    }

    /// **The account has no entry of its own: the server's assignment decides**
    /// (Alex's READY, 2026-11-17: `reader=none`, three servers at variant 1,
    /// and Discord drew the hub on his test server).
    @Test("With no account entry, a server marked on in the experiment has its hub")
    func serverAssignmentDecidesWithoutReader() async {
        await withAppSettings(\.showsServerHub) { settings in
            settings.showsServerHub = true
            let hash = MurmurHash3.hash32(AppModel.serverHubExperiment)
            let other = MurmurHash3.hash32("2026-01-some-other-experiment")
            @MainActor func noReaderEntry(_ model: AppModel, variant: Int?) -> AppModel {
                // Experiment data exists, just none of the account's for this one.
                model.experiments = ExperimentSnapshot(apexReader: [
                    other: ApexAssignment(hash: other, variantID: 1, isOverride: false, revision: 1),
                ])
                model.guilds[guildID]?.apexAssignments = variant.map {
                    [hash: ApexAssignment(hash: hash, variantID: $0, isOverride: false, revision: 3)]
                } ?? [:]
                return model
            }
            let published = GuildSpaceSettings(isEnabled: true, publishStatus: .published)
            #expect(noReaderEntry(model(isOwner: false, settings: published), variant: 1).offersServerHub(guildID))
            #expect(!noReaderEntry(model(isOwner: false, settings: published), variant: 0).offersServerHub(guildID))
            #expect(!noReaderEntry(model(isOwner: false, settings: published), variant: nil).offersServerHub(guildID))
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
