import Foundation
import Testing
import WingcordCore
import WingcordNet
@testable import Wingcord

/// Summaries: which channels have them, when they are asked for, where the
/// reader is among them, and what going to one does. And which server's theme
/// the window wears.
@Suite("Summaries")
@MainActor
struct SummaryTests {

    private let channel = ChannelID(rawValue: 1001)
    private let other = ChannelID(rawValue: 1002)
    private let guild = GuildID(rawValue: 100)

    /// A summary spanning `start ... end`.
    private func summary(_ start: UInt64, _ end: UInt64, count: Int = 5) -> ChannelSummary {
        ChannelSummary(
            id: ChannelSummaryID(rawValue: start + 1),
            topic: "Topic \(start)",
            summary: "About \(start).",
            people: [],
            startMessageID: MessageID(rawValue: start),
            endMessageID: MessageID(rawValue: end),
            messageCount: count
        )
    }

    private func model(features: Set<String> = Set(AppModel.summaryFeatures)) -> AppModel {
        let model = AppModel()
        model.guilds = [
            guild: Guild(id: guild, name: "Previews", ownerID: UserID(rawValue: 2), features: features),
        ]
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: channel, kind: .text, guildID: guild, name: "general"),
                Channel(id: other, kind: .text, guildID: guild, name: "off-topic"),
            ],
            inGuild: guild
        )
        model.channelIndex = index
        return model
    }

    // MARK: Where

    @Test("A plain text channel of a server with both flags has summaries")
    func gate() {
        let model = model()
        #expect(model.summariesApply(to: channel))
        model.guilds[guild]?.features = ["SUMMARIES_ENABLED_GA"]
        #expect(!model.summariesApply(to: channel))
    }

    @Test("Not the rules channel, not an age-restricted one, and not one switched off")
    func gateExclusions() {
        let model = model()
        model.guilds[guild]?.rulesChannelID = channel
        #expect(!model.summariesApply(to: channel))
        #expect(model.summariesApply(to: other))

        model.guilds[guild]?.rulesChannelID = nil
        model.guilds[guild]?.isAgeRestricted = true
        #expect(!model.summariesApply(to: channel))

        let fresh = self.model()
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: channel, kind: .text, guildID: guild, name: "general", isNSFW: true),
                Channel(id: other, kind: .text, guildID: guild, name: "quiet", flags: .summariesDisabled),
            ],
            inGuild: guild
        )
        fresh.channelIndex = index
        #expect(!fresh.summariesApply(to: channel))
        #expect(!fresh.summariesApply(to: other))
    }

    // MARK: When

    @Test("The list is asked for once a session, and a refusal is final")
    func asksOnce() {
        let model = model()
        var requests: [SummaryRequest] = []
        model.summaryLoader = { _, request in requests.append(request) }

        model.loadSummariesIfNeeded(in: channel)
        model.loadSummariesIfNeeded(in: channel)
        #expect(requests == [.list])

        model.applySummaries([summary(100, 150)], in: channel)
        model.loadSummariesIfNeeded(in: channel)
        #expect(requests == [.list])

        // A new session asks again — and keeps what it has meanwhile.
        model.markSummariesStale()
        #expect(!model.summaries(in: channel).isEmpty)
        model.loadSummariesIfNeeded(in: channel)
        #expect(requests == [.list, .list])

        model.loadSummariesIfNeeded(in: other)
        model.failSummaries(in: other, refused: true)
        model.markSummariesStale()
        model.loadSummariesIfNeeded(in: other)
        #expect(requests.count == 3)
    }

    @Test("A dropped connection lets the next visit ask again")
    func retryAfterFailure() {
        let model = model()
        var requests = 0
        model.summaryLoader = { _, _ in requests += 1 }
        model.loadSummariesIfNeeded(in: channel)
        model.failSummaries(in: channel, refused: false)
        model.loadSummariesIfNeeded(in: channel)
        #expect(requests == 2)
    }

    @Test("A live update lands before the list and survives it; the list replaces its own")
    func liveThenList() {
        let model = model()
        model.summaryLoader = { _, _ in }
        model.loadSummariesIfNeeded(in: channel)
        var grown = summary(100, 150)
        model.mergeSummaries([summary(300, 350)], in: channel)
        model.mergeSummaries([grown], in: channel)
        grown.messageCount = 9
        model.applySummaries([summary(200, 250), grown], in: channel)
        let starts = model.summaries(in: channel).map(\.startMessageID.rawValue)
        // Newest first by where each begins.
        #expect(starts == [300, 200, 100])
        #expect(model.summaries(in: channel).last?.messageCount == 9)
        #expect(model.channelSummaries[channel]?.hasFetched == true)
    }

    // MARK: Where the reader is

    private let list = [
        // Newest first; the first two interleave, as real stretches do.
        ChannelSummary(
            id: ChannelSummaryID(rawValue: 1), topic: "Badges", summary: "", people: [],
            startMessageID: MessageID(rawValue: 400), endMessageID: MessageID(rawValue: 900), messageCount: 28
        ),
        ChannelSummary(
            id: ChannelSummaryID(rawValue: 2), topic: "Wallpapers", summary: "", people: [],
            startMessageID: MessageID(rawValue: 300), endMessageID: MessageID(rawValue: 450), messageCount: 3
        ),
        ChannelSummary(
            id: ChannelSummaryID(rawValue: 3), topic: "Credits", summary: "", people: [],
            startMessageID: MessageID(rawValue: 100), endMessageID: MessageID(rawValue: 150), messageCount: 19
        ),
    ]

    private func place(_ top: UInt64?, _ bottom: UInt64?, highlighted: UInt64? = nil) -> SummaryPlace {
        SummaryPlace(
            top: top.map(MessageID.init(rawValue:)),
            bottom: bottom.map(MessageID.init(rawValue:)),
            highlighted: highlighted.map(ChannelSummaryID.init(rawValue:)),
            summaries: list
        )
    }

    @Test("The bar names the newest stretch on screen — Discord's rule")
    func namesNewestOverlapping() {
        let place = place(420, 440)
        #expect(place.current == 0)
        #expect(place.title(in: list) == "Badges")
        #expect(place.older == 1)
        #expect(place.newer == nil)
    }

    @Test("Going to a summary names it until the reader scrolls, even where a newer one overlaps")
    func highlightWins() {
        let place = place(420, 440, highlighted: 2)
        #expect(place.current == 1)
        #expect(place.title(in: list) == "Wallpapers")
        #expect(place.older == 2)
        #expect(place.newer == 0)
    }

    @Test("At the present nothing is on screen, the newest is named, and up goes to it")
    func atPresent() {
        let place = place(nil, nil)
        #expect(place.isAtPresent)
        #expect(place.current == nil)
        #expect(place.title(in: list) == "Badges")
        #expect(place.older == 0)
        #expect(place.newer == nil)
    }

    @Test("Between stretches the pill offers the list, and the arrows go to the nearest either side")
    func between() {
        let place = place(200, 250)
        #expect(place.current == nil)
        #expect(place.title(in: list) == SummaryPlace.allSummaries)
        #expect(place.older == 2)
        #expect(place.newer == 1)
    }

    // MARK: Going to one

    @Test("Going to a summary marks it, asks for it fresh at most every five seconds, and jumps")
    func openSummary() {
        let model = model()
        var requests: [SummaryRequest] = []
        model.summaryLoader = { _, request in requests.append(request) }
        let target = summary(100, 150, count: 19)
        model.applySummaries([target], in: channel)
        model.mutateBox(channel) { box in
            box.receiveAround(
                [Message(id: target.startMessageID, channelID: channel, authorID: UserID(rawValue: 1), content: "x")],
                edges: (older: false, newer: false)
            )
        }
        model.selectedChannelID = channel

        model.openSummary(target, in: channel)
        let first = model.selectedSummary
        #expect(first?.summaryID == target.id)
        #expect(model.pendingJump?.messageID == target.startMessageID)
        model.openSummary(target, in: channel)
        // Two goings are two landings, and one fetch.
        #expect(model.selectedSummary?.token != first?.token)
        #expect(requests == [.one(target.id)])

        // Its mark is in the transcript, above where it begins.
        let rows = model.timelineRows(for: channel)
        #expect(rows.contains { row in
            if case .marker(.summary, let id, let title) = row {
                id == target.id.rawValue && title == target.topic
            } else { false }
        })
    }

    @Test("Leaving the channel forgets the summary the reader went to — and nothing else does")
    func selectionClears() {
        let model = model()
        model.selectedChannelID = channel
        model.selectedSummary = SelectedSummary(
            channelID: channel, summaryID: ChannelSummaryID(rawValue: 7), token: 1
        )
        model.selectedChannelID = channel
        #expect(model.selectedSummary != nil)
        model.selectedChannelID = other
        #expect(model.selectedSummary == nil)
    }

    @Test("The toolbar offers the switch only where there are summaries to hide")
    func toolbarGate() {
        let model = model()
        model.selectedGuildID = guild
        model.selectedChannelID = channel
        #expect(!model.channelChrome.canShowSummaries)
        model.applySummaries([summary(100, 150)], in: channel)
        #expect(model.channelChrome.canShowSummaries)
        model.selectedChannelID = other
        #expect(!model.channelChrome.canShowSummaries)
    }

    // MARK: Server themes

    @Test("A server's theme is worn while it is selected, has the feature, is on, and is wanted")
    func activeServerTheme() {
        let model = model(features: [AppModel.serverThemeFeature])
        let fire = GuildTheme(isEnabled: true, presetID: 3)
        model.guilds[guild]?.theme = fire
        #expect(model.activeServerTheme == nil)

        model.selectedGuildID = guild
        #expect(model.activeServerTheme == ActiveServerTheme(guildID: guild, theme: fire))

        // The reader's default, then a per-server override over it.
        model.serverThemePreferences.default = .personal
        #expect(model.activeServerTheme == nil)
        model.serverThemePreferences.overrides[guild] = .guild
        #expect(model.activeServerTheme != nil)
        model.serverThemePreferences = ServerThemePreferences()

        model.guilds[guild]?.features = []
        #expect(model.activeServerTheme == nil)
        model.guilds[guild]?.features = [AppModel.serverThemeFeature]
        model.guilds[guild]?.theme?.isEnabled = false
        #expect(model.activeServerTheme == nil)
    }
}
