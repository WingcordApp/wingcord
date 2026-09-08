import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The quick switcher, driven through the real store.
///
/// `QuickSwitchTests` in `WingcordCore` owns the grammar and the scorer. What is
/// worth pinning here is the half those cannot see: which places become
/// candidates at all, what a row says, and where picking one goes — all of which
/// are answered by walking the account and are therefore the half that can be
/// wired up wrongly while every unit test still passes. §2's rule: a test for a
/// surface goes through the projection the view actually reads.
@Suite("Quick switcher panel")
@MainActor
struct QuickSwitchPanelTests {

    private let readerID = UserID(rawValue: 1)
    private let friendID = UserID(rawValue: 2)
    private let strangerID = UserID(rawValue: 3)

    private let homeGuild = GuildID(rawValue: 1000)
    private let coldGuild = GuildID(rawValue: 2000)

    private let category = ChannelID(rawValue: 1001)
    private let general = ChannelID(rawValue: 1002)
    private let lounge = ChannelID(rawValue: 1003)
    private let secret = ChannelID(rawValue: 1004)
    private let broCave = ChannelID(rawValue: 1005)
    private let coldGeneral = ChannelID(rawValue: 2002)
    private let dm = ChannelID(rawValue: 3001)

    /// A small account with everything the switcher has to tell apart: two
    /// servers with a same-named channel in each, a category, a voice channel,
    /// one channel nobody may read, a conversation and a person with no
    /// conversation.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [
            readerID: User(id: readerID, username: "reader"),
            friendID: User(id: friendID, username: "pebblecourt", displayName: "Pebblecourt"),
            strangerID: User(id: strangerID, username: "lucapts2s", displayName: "5por9"),
        ]
        model.relationships = [friendID: .friend, strangerID: .friend]
        model.presences = [friendID: Presence(userID: friendID, status: .online)]

        model.guilds = [
            homeGuild: Guild(id: homeGuild, name: "Lumen Club", ownerID: readerID),
            coldGuild: Guild(id: coldGuild, name: "DevilBro's Haus", ownerID: strangerID),
        ]
        // Everything visible by default: the reader owns the home server, and
        // `@everyone` in the other one carries the two bits a reader needs.
        let everyone = RoleID(rawValue: coldGuild.rawValue)
        model.roles[coldGuild] = [
            everyone: Role(
                id: everyone,
                name: "@everyone",
                position: 0,
                permissions: [.viewChannel, .readMessageHistory]
            ),
        ]
        model.members[coldGuild] = [readerID: Member(userID: readerID, roleIDs: [])]

        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: category, kind: .category, guildID: homeGuild, name: "MAIN"),
                Channel(
                    id: general, kind: .text, guildID: homeGuild,
                    name: "general", parentID: category, position: 1,
                    lastMessageID: MessageID(rawValue: 900)
                ),
                Channel(
                    id: lounge, kind: .voice, guildID: homeGuild,
                    name: "lounge", position: 2
                ),
                // Denied to `@everyone` *and* to the reader's own role, so the
                // owner's implicit grant is not what lets it through.
                Channel(
                    id: secret, kind: .text, guildID: homeGuild,
                    name: "general-secrets", position: 3
                ),
                // A cold word-prefix match, so the ordering tests have a
                // candidate that beats a `contains` on merit alone.
                Channel(
                    id: broCave, kind: .text, guildID: homeGuild,
                    name: "the-bro-cave", position: 4
                ),
            ],
            inGuild: homeGuild
        )
        index.replaceChannels(
            [
                Channel(
                    id: coldGeneral, kind: .text, guildID: coldGuild,
                    name: "general", position: 1,
                    lastMessageID: MessageID(rawValue: 800)
                ),
            ],
            inGuild: coldGuild
        )
        index.replacePrivateChannels([
            Channel(
                id: dm, kind: .directMessage, name: "",
                lastMessageID: MessageID(rawValue: 700),
                recipientIDs: [friendID]
            ),
        ])
        model.channelIndex = index
        model.selectedGuildID = homeGuild
        model.selectedChannelID = general
        return model
    }

    private func rows(_ model: AppModel) -> [QuickSwitchRow] {
        model.quickSwitchSections.flatMap(\.rows)
    }

    private func titles(_ model: AppModel) -> [String] {
        rows(model).map(\.title)
    }

    // MARK: Opening

    @Test("⌘K opens and closes, and never reopens on the last thing typed")
    func togglingOpensEmpty() {
        let model = model()
        model.toggleQuickSwitch()
        #expect(model.isQuickSwitchShown)

        model.setQuickSwitchText("gen")
        model.toggleQuickSwitch()
        #expect(!model.isQuickSwitchShown)

        model.toggleQuickSwitch()
        #expect(model.quickSwitch?.text.isEmpty == true)
    }

    // MARK: The empty state

    /// The switcher's top row is where Return goes. Offering the channel
    /// somebody is already reading makes ⌘K↵ do nothing; leaving it out makes
    /// the same two keys mean "back to the last one".
    @Test("Previous channels leaves out the channel on screen")
    func previousExcludesTheOpenChannel() {
        let model = model()
        model.recordChannelVisit(general)
        model.selectedChannelID = coldGeneral
        model.recordChannelVisit(coldGeneral)

        model.toggleQuickSwitch()
        let previous = model.quickSwitchSections.first { $0.id == "previous" }
        #expect(previous?.rows.map(\.target) == [.channel(general)])
    }

    /// The frecency table is what fills that list on the first ⌘K of a session,
    /// before which a freshly-launched client has nothing to show at all.
    @Test("Discord's own table seeds the list before anything is visited")
    func frecencySeedsPreviousChannels() {
        let model = model()
        model.placeFrecency = [
            coldGeneral.rawValue: PlaceFrecency(score: 500, lastUsedAt: .now),
        ]
        model.toggleQuickSwitch()
        let previous = model.quickSwitchSections.first { $0.id == "previous" }
        #expect(previous?.rows.map(\.target) == [.channel(coldGeneral)])
    }

    @Test("Mentions lists the channels with something addressed to the reader")
    func mentionsAreListed() {
        let model = model()
        model.readStates = [
            coldGeneral: ReadState(mentionCount: 3),
            general: ReadState(mentionCount: 0),
        ]
        model.toggleQuickSwitch()
        let mentions = model.quickSwitchSections.first { $0.id == "mentions" }
        #expect(mentions?.rows.map(\.target) == [.channel(coldGeneral)])
        #expect(mentions?.rows.first?.mentionCount == 3)
    }

    /// A muted channel's unread never reaches the rail, and it must not reach
    /// this list either — it is the same statement in a second place.
    @Test("A muted channel's mentions stay out of the list")
    func mutedMentionsAreHidden() {
        let model = model()
        model.readStates = [coldGeneral: ReadState(mentionCount: 3, isMuted: true)]
        model.toggleQuickSwitch()
        #expect(model.quickSwitchSections.first { $0.id == "mentions" } == nil)
    }

    // MARK: What becomes a candidate

    @Test("A channel the reader cannot open is never offered")
    func hiddenChannelsAreNotCandidates() {
        let model = model()
        // Deny it to everyone, including the owner's own implicit grant.
        model.guilds[homeGuild]?.ownerID = strangerID
        model.roles[homeGuild] = [
            RoleID(rawValue: homeGuild.rawValue): Role(
                id: RoleID(rawValue: homeGuild.rawValue),
                name: "@everyone",
                position: 0,
                permissions: []
            ),
        ]
        model.members[homeGuild] = [readerID: Member(userID: readerID, roleIDs: [])]
        model.roleRevision &+= 1

        model.toggleQuickSwitch()
        model.setQuickSwitchText("secret")
        #expect(rows(model).isEmpty)
    }

    /// A category is a heading and a thread is reached through its parent.
    /// Neither is a place this can send anybody, and a row that goes nowhere is
    /// the inert control §5.5 forbids.
    @Test("A category is not a destination")
    func categoriesAreNotCandidates() {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("main")
        #expect(!rows(model).contains { $0.target == .channel(category) })
    }

    // MARK: The sigils

    @Test("Each sigil narrows to its own kind")
    func sigilsNarrow() {
        let model = model()
        model.toggleQuickSwitch()

        model.setQuickSwitchText("#")
        #expect(titles(model).contains("general"))
        #expect(!titles(model).contains("lounge"))

        model.setQuickSwitchText("!")
        #expect(titles(model) == ["lounge"])

        model.setQuickSwitchText("*")
        #expect(Set(titles(model)) == ["Lumen Club", "DevilBro's Haus"])

        model.setQuickSwitchText("@")
        #expect(Set(titles(model)) == ["Pebblecourt", "5por9"])
    }

    /// A mode with nothing typed still says what it is. A blank panel with no
    /// heading reads as a switcher that broke rather than one that is waiting.
    @Test("A sigil with nothing after it still names its mode")
    func aBareSigilNamesItsMode() {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("$")
        #expect(model.quickSwitchFilter == .games)
        #expect(model.quickSwitchSections.map(\.title) == [QuickSwitchFilter.games.title])
    }

    // MARK: What a row says

    /// The two things that tell two `#general`s apart.
    @Test("A channel row carries its category and its server")
    func channelRowNamesItsPlace() throws {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("#general")
        let row = try #require(rows(model).first { $0.target == .channel(general) })
        #expect(row.label == "MAIN")
        #expect(row.trailing == "Lumen Club")
    }

    @Test("A person's row carries their handle and their presence")
    func personRowNamesTheAccount() throws {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("@pebble")
        let row = try #require(rows(model).first)
        #expect(row.title == "Pebblecourt")
        #expect(row.subtitle == "pebblecourt")
        #expect(row.status == .online)
        #expect(row.isPerson)
    }

    /// The handle is how somebody with a display name nobody can spell is found.
    @Test("A person is found by their handle as well as their name")
    func handlesAreMatched() {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("@lucapts")
        #expect(titles(model) == ["5por9"])
    }

    // MARK: Ordering

    /// The capture's own case, and the whole reason the score is a weighted sum:
    /// `DevilBro's Haus` merely *contains* the letters, `the-bro-cave` starts a
    /// word with them, and the server the account lives in still comes first.
    @Test("A place the account uses outranks a cold better match")
    func frecencyDecidesBetweenTiers() {
        let model = model()
        model.placeFrecency = [coldGuild.rawValue: PlaceFrecency(score: 1000)]
        model.toggleQuickSwitch()
        model.setQuickSwitchText("bro")
        #expect(rows(model).first?.target == .guild(coldGuild))
    }

    /// And with nothing to separate them the tiers decide, which is what stops
    /// the switcher becoming a most-recently-used list wearing a search field.
    @Test("With no frecency at all, the better match wins")
    func matchDecidesWithoutFrecency() {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("bro")
        #expect(rows(model).first?.target == .channel(broCave))
    }

    // MARK: Games

    /// The answer is drawn only against the question it answers — otherwise a
    /// round trip that lands two keystrokes late draws `Grand Theft Auto V`
    /// under a field that says something else.
    @Test("Game hits are drawn only for the needle they answer")
    func gamesTrackTheirQuery() {
        let model = model()
        model.toggleQuickSwitch()
        model.quickSwitch?.text = "gta"
        model.quickSwitch?.games = [
            GameSummary(id: ApplicationID(rawValue: 42), name: "Grand Theft Auto V"),
        ]
        model.quickSwitch?.gamesNeedle = "gta"
        #expect(titles(model).contains("Grand Theft Auto V"))

        model.quickSwitch?.text = "gtaa"
        #expect(!titles(model).contains("Grand Theft Auto V"))
    }

    /// A game profile is a different kind of destination from a place in your
    /// account, and three of them is the reference client's own trade.
    @Test("A mixed list takes three game profiles; $ takes them all")
    func gamesAreCappedInAMixedList() {
        let model = model()
        model.toggleQuickSwitch()
        let games = (0..<6).map {
            GameSummary(id: ApplicationID(rawValue: UInt64(100 + $0)), name: "Bro Game \($0)")
        }
        model.quickSwitch?.text = "bro"
        model.quickSwitch?.games = games
        model.quickSwitch?.gamesNeedle = "bro"
        #expect(model.quickSwitchSections.first { $0.id == "games" }?.rows.count == 3)

        model.quickSwitch?.text = "$bro"
        #expect(model.quickSwitchSections.first { $0.id == "games" }?.rows.count == 6)
    }

    // MARK: Going somewhere

    @Test("Picking a channel selects its server and closes the panel")
    func pickingAChannelNavigates() throws {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("#general")
        let row = try #require(rows(model).first { $0.target == .channel(coldGeneral) })

        model.openQuickSwitchRow(row)
        #expect(!model.isQuickSwitchShown)
        #expect(model.selectedGuildID == coldGuild)
        #expect(model.selectedChannelID == coldGeneral)
    }

    /// Going somewhere dismisses the card about somewhere else — ⌘K is reached
    /// from on top of a profile, and a card left floating over the channel it
    /// just sent you to is chrome describing where you no longer are.
    @Test("Picking a row takes down whatever it was opened over")
    func pickingDismissesRaisedSurfaces() throws {
        let model = model()
        model.profileRequest = ProfileRequest(userID: friendID, anchor: .zero)
        model.toggleQuickSwitch()
        model.setQuickSwitchText("*sakura")
        let row = try #require(rows(model).first)

        model.openQuickSwitchRow(row)
        #expect(model.profileRequest == nil)
    }

    @Test("Picking a person opens the conversation with them")
    func pickingAPersonOpensTheirDM() throws {
        let model = model()
        model.toggleQuickSwitch()
        model.setQuickSwitchText("@pebble")
        let row = try #require(rows(model).first)

        model.openQuickSwitchRow(row)
        #expect(model.selectedGuildID == nil)
        #expect(model.selectedChannelID == dm)
    }

    // MARK: Recording where you have been

    /// A channel read beside a server's guide is a peek, not a visit. Recording
    /// one would fill the Previous list with pages nobody navigated to.
    @Test("A previewed channel is not a visit")
    func previewsAreNotVisits() {
        let model = model()
        model.previewedChannelID = coldGeneral
        model.channelDidOpen(coldGeneral)
        #expect(model.recentChannelIDs.isEmpty)
    }

    @Test("Revisiting moves a channel to the front rather than repeating it")
    func visitsAreDeduplicated() {
        let model = model()
        model.recordChannelVisit(general)
        model.selectedChannelID = coldGeneral
        model.recordChannelVisit(coldGeneral)
        model.selectedChannelID = general
        model.recordChannelVisit(general)
        #expect(model.recentChannelIDs == [general, coldGeneral])
    }

    @Test("The visit list is bounded")
    func visitsAreBounded() {
        let model = model()
        for raw in 0..<20 {
            let id = ChannelID(rawValue: UInt64(5000 + raw))
            model.selectedChannelID = id
            model.recordChannelVisit(id)
        }
        #expect(model.recentChannelIDs.count == AppModel.visitsRemembered)
    }
}
