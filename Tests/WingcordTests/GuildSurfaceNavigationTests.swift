import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The rows above a server's first category, and what selecting one does.
///
/// What is worth pinning here is not the pages but the **gates**: a row that
/// opens onto "this server has not set one up" is the inert control §5.5
/// forbids, and none of these three has a flag on the guild object that
/// predicts it — so each is gated on its own route having answered.
@Suite("Guild surface navigation")
@MainActor
struct GuildSurfaceNavigationTests {

    // A row's channel name, for the assertions that care about the list's
    // contents rather than its shape.


    private let guildID = GuildID(rawValue: 1000)

    private let readerID = UserID(rawValue: 1)

    /// **The reader owns the fixture server**, which is the shortest way to a
    /// permissive gate: `PermissionGate` fails closed on every unknown, so a
    /// store with no signed-in account resolves every channel to invisible and
    /// the browser is correctly, unhelpfully, empty.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(
            id: guildID,
            name: "The Iris Project",
            ownerID: readerID,
            features: ["COMMUNITY"]
        )
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID, name: "general", position: 0),
                Channel(id: ChannelID(rawValue: 2002), kind: .text, guildID: guildID, name: "faq", position: 1),
            ],
            inGuild: guildID
        )
        model.channelIndex = index
        model.selectedGuildID = guildID
        return model
    }

    // MARK: The gates

    /// **Nothing has answered yet.** The channel list's own row is still there,
    /// because a channel list is something every server has — and it takes the
    /// name that is true before the questions arrive.
    @Test("A server nothing is known about offers only its channel list")
    func unknownServerOffersOnlyBrowse() {
        let model = model()
        #expect(model.guildSurfaceRows(for: guildID) == [.browseChannels, .members])
    }

    /// The row **upgrades in place** once the questions land. A label changing
    /// is far less jarring than a row appearing, and it is never a lie.
    @Test("Questions arriving rename the row rather than adding one")
    func onboardingRenamesTheRow() {
        let model = model()
        model.guildOnboardings[guildID] = GuildOnboarding(
            guildID: guildID,
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(
                    id: 1,
                    title: "Region",
                    options: [GuildOnboarding.Option(id: 2, title: "Europe")]
                )
            ]
        )
        #expect(model.guildSurfaceRows(for: guildID) == [.channelsAndRoles, .members])
    }

    /// A community server whose onboarding is configured but empty must not
    /// promise roles it does not have.
    @Test("Onboarding with no prompts leaves the row as Browse Channels")
    func emptyOnboardingKeepsBrowse() {
        let model = model()
        model.guildOnboardings[guildID] = GuildOnboarding(guildID: guildID, isEnabled: true)
        #expect(model.guildSurfaceRows(for: guildID) == [.browseChannels, .members])
    }

    /// A guide that answered `enabled: false`, or answered with nothing in it,
    /// is a guide there is no row for.
    @Test("An empty or disabled guide gets no row")
    func emptyGuideGetsNoRow() {
        let model = model()
        model.serverGuides[guildID] = ServerGuide(guildID: guildID, isEnabled: true)
        #expect(model.guildSurfaceRows(for: guildID) == [.browseChannels, .members])

        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: false,
            resources: [ServerGuide.Resource(id: 0, channelID: ChannelID(rawValue: 2001), title: "Links")]
        )
        #expect(model.guildSurfaceRows(for: guildID) == [.browseChannels, .members])
    }

    @Test("A guide with something in it comes first")
    func guideLeadsTheList() {
        let model = model()
        // Discord's tests for a guide (`offersServerGuide`): the server's
        // features, and a newcomer who has not finished it.
        model.guilds[guildID]?.features.formUnion(["COMMUNITY", "GUILD_SERVER_GUIDE", "GUILD_ONBOARDING"])
        model.members[guildID] = [readerID: Member(userID: readerID, joinedAt: .now)]
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            resources: [ServerGuide.Resource(id: 0, channelID: ChannelID(rawValue: 2001), title: "Links")]
        )
        model.gameServers[guildID] = [
            GameServer(id: 5, skuID: "s", name: "Server", status: .online)
        ]
        // Order is the server's own: the front page, the way in, the
        // moderators' Members, the extras.
        #expect(model.guildSurfaceRows(for: guildID) == [.serverGuide, .browseChannels, .members, .gameServers])
    }

    @Test("A finished guide, or a member of more than a week, has no row — as on Discord")
    func guideLeavesWhenDone() {
        let model = model()
        model.guilds[guildID]?.features.formUnion(["COMMUNITY", "GUILD_SERVER_GUIDE", "GUILD_ONBOARDING"])
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            resources: [ServerGuide.Resource(id: 0, channelID: ChannelID(rawValue: 2001), title: "Links")]
        )
        model.members[guildID] = [readerID: Member(userID: readerID, joinedAt: .now, flags: .completedHomeActions)]
        #expect(!model.guildSurfaceRows(for: guildID).contains(.serverGuide))
        model.members[guildID] = [readerID: Member(userID: readerID, joinedAt: .now.addingTimeInterval(-8 * 24 * 60 * 60))]
        #expect(!model.guildSurfaceRows(for: guildID).contains(.serverGuide))
    }

    @Test("A guide's answer alone is not a row: the server must offer one, as Discord asks")
    func guideNeedsTheFeatures() {
        let model = model()
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            resources: [ServerGuide.Resource(id: 0, channelID: ChannelID(rawValue: 2001), title: "Links")]
        )
        #expect(!model.guildSurfaceRows(for: guildID).contains(.serverGuide))
    }

    /// 403, 404 and `[]` all mean the same thing to this row, and all three are
    /// stored as an empty array so the question is not asked twice.
    @Test("A server that rents no game servers gets no row")
    func noGameServersNoRow() {
        let model = model()
        model.gameServers[guildID] = []
        #expect(model.guildSurfaceRows(for: guildID) == [.browseChannels, .members])
    }

    /// **The fixture's reader owns a community server**, which is a moderator
    /// by Discord's rule — so every list above carries Members. Somebody with
    /// no moderator permission, or a server that is neither community nor
    /// given the moderation experience, does not.
    @Test("The Members row is a moderator's, in a community server")
    func membersRowIsGated() {
        let plain = model()
        plain.guilds[guildID]?.features = []
        #expect(plain.guildSurfaceRows(for: guildID) == [.browseChannels])

        let member = model()
        member.guilds[guildID]?.ownerID = UserID(rawValue: 77)
        member.members[guildID] = [readerID: Member(userID: readerID)]
        member.permissionGate.invalidate()
        #expect(member.guildSurfaceRows(for: guildID) == [.browseChannels])
    }

    // MARK: Selection

    /// One value, so a channel and a page cannot both be lit in the sidebar.
    @Test("A page and a channel are never both the target")
    func targetIsExclusive() {
        let model = model()
        model.selectedChannelID = ChannelID(rawValue: 2001)
        #expect(model.sidebarTarget == .channel(ChannelID(rawValue: 2001)))

        model.openSurface(.browseChannels)
        #expect(model.sidebarTarget == .surface(.browseChannels))
        // The channel is remembered, not discarded — leaving the page returns
        // to the conversation that was open.
        #expect(model.selectedChannelID == ChannelID(rawValue: 2001))
    }

    /// **Picking a channel leaves the page even when it is the channel you came
    /// from.** Guarded on the id alone, clicking the row you started at would
    /// leave the page up and do nothing at all.
    @Test("Selecting the channel already selected still closes the page")
    func reselectingTheSameChannelClosesThePage() {
        let model = model()
        model.selectedChannelID = ChannelID(rawValue: 2001)
        model.openSurface(.browseChannels)
        model.selectChannel(ChannelID(rawValue: 2001))
        #expect(model.openGuildSurface == nil)
        #expect(model.sidebarTarget == .channel(ChannelID(rawValue: 2001)))
    }

    /// A guide belongs to the server it describes.
    @Test("Switching servers closes the page")
    func switchingServersClosesThePage() {
        let model = model()
        model.openSurface(.serverGuide)
        model.selectGuild(nil)
        #expect(model.openGuildSurface == nil)
    }

    // MARK: The chrome

    /// The pill names whatever the column is showing. Its own branch rather than
    /// a nil channel, so the bar has a title there instead of a hole its
    /// neighbours slide into.
    @Test("The toolbar names the page and offers no roster beside it")
    func chromeNamesThePage() {
        let model = model()
        model.selectedChannelID = ChannelID(rawValue: 2001)
        model.openSurface(.gameServers)
        let chrome = model.channelChrome
        #expect(chrome.name == "Game Servers")
        #expect(chrome.symbolName == GuildSurface.gameServers.symbolName)
        #expect(!chrome.canShowMemberList)
        #expect(!chrome.canShowUserProfile)
        #expect(chrome.channelID == nil)
    }

    /// A page is about the server, so nothing belongs beside it.
    @Test("The detail column gives a page the whole width")
    func pageTakesTheWholeColumn() {
        let model = model()
        model.selectedChannelID = ChannelID(rawValue: 2001)
        model.isMemberListShown = true
        model.openSurface(.serverGuide)
        let presentation = model.workspacePresentation
        #expect(presentation.primary == .guildSurface(guildID, .serverGuide))
        #expect(presentation.supplementary == nil)
    }

    // MARK: The channel browser

    /// The same permission filter as the sidebar's, and for the same reason: a
    /// channel the reader cannot view does not exist, and a row for one would be
    /// a door that does not open.
    @Test("The browser lists every visible channel, grouped, with its own count")
    func browserGroupsChannels() throws {
        let model = model()
        var index = ChannelIndex()
        let categoryID = ChannelID(rawValue: 3000)
        index.replaceChannels(
            [
                Channel(id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID, name: "loose", position: 0),
                Channel(id: categoryID, kind: .category, guildID: guildID, name: "INFO", position: 1),
                Channel(
                    id: ChannelID(rawValue: 2002), kind: .text, guildID: guildID,
                    name: "rules", topic: "Read these", parentID: categoryID, position: 2
                ),
                // A category with no visible children is a heading over nothing.
                Channel(id: ChannelID(rawValue: 3001), kind: .category, guildID: guildID, name: "EMPTY", position: 3),
            ],
            inGuild: guildID
        )
        model.channelIndex = index

        let page = try #require(model.channelsAndRolesPresentation)
        #expect(page.categories.count == 2)
        #expect(page.categories[0].title == nil)
        #expect(page.categories[1].title == "INFO")
        #expect(page.channelCount == 2)
        #expect(page.categories[1].channels[0].topic == "Read these")
        #expect(!page.asksQuestions)
    }

    /// The search key is folded once with the row rather than at each keystroke,
    /// and it covers the topic as well as the name — searching for what a
    /// channel is *about* is most of why somebody opens this page.
    @Test("Search matches a name or a topic, case-folded")
    func searchMatchesNameAndTopic() throws {
        let model = model()
        var index = ChannelIndex()
        index.replaceChannels(
            [Channel(
                id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID,
                name: "General", topic: "Anything at all", position: 0
            )],
            inGuild: guildID
        )
        model.channelIndex = index

        let page = try #require(model.channelsAndRolesPresentation)
        let channel = try #require(page.categories.first?.channels.first)
        #expect(channel.matches("gener"))
        #expect(channel.matches("anything"))
        #expect(channel.matches(""))
        #expect(!channel.matches("releases"))
    }

    /// The memo has to answer the same value twice for the page to be worth
    /// having — and it has to notice an answer landing.
    @Test("The page is memoized, and a new answer invalidates it")
    func pageIsMemoized() throws {
        let model = model()
        let first = try #require(model.channelsAndRolesPresentation)
        let second = try #require(model.channelsAndRolesPresentation)
        #expect(first == second)

        model.guildOnboardings[guildID] = GuildOnboarding(
            guildID: guildID,
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(
                    id: 1,
                    title: "Region",
                    options: [GuildOnboarding.Option(id: 2, title: "Europe")]
                )
            ]
        )
        let third = try #require(model.channelsAndRolesPresentation)
        #expect(third.asksQuestions)
        #expect(third.prompts.count == 1)
    }

    /// An option's footnote is what it *does*, and a role the store has not seen
    /// is dropped rather than drawn as its id.
    @Test("An option says which role it grants and how many channels it reveals")
    func optionStatesWhatItUnlocks() throws {
        let model = model()
        let roleID = RoleID(rawValue: 4000)
        model.roles[guildID] = [
            roleID: Role(id: roleID, name: "Europe", colorValue: 0x5865F2, position: 3)
        ]
        model.roleMemberCounts[guildID] = [roleID: 186_202]
        model.guildOnboardings[guildID] = GuildOnboarding(
            guildID: guildID,
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(
                    id: 1,
                    title: "Region",
                    options: [
                        GuildOnboarding.Option(
                            id: 2,
                            title: "Europe",
                            roleIDs: [roleID],
                            channelIDs: [ChannelID(rawValue: 2001), ChannelID(rawValue: 2002)]
                        ),
                        GuildOnboarding.Option(id: 3, title: "Nowhere"),
                    ]
                )
            ],
            responses: [2]
        )

        let page = try #require(model.channelsAndRolesPresentation)
        let option = page.prompts[0].options[0]
        #expect(option.isSelected)
        #expect(option.unlocks == "Europe · 2 channels")
        #expect(option.roleColorValue == 0x5865F2)
        #expect(option.memberCount == 186_202)
        // An option that grants nothing says nothing rather than an empty line.
        #expect(page.prompts[0].options[1].unlocks == nil)
        #expect(!page.prompts[0].options[1].isSelected)
    }

    /// The optimistic write is the whole reason a chip responds on the press.
    @Test("Answering moves the store before the route is asked")
    func answeringIsOptimistic() {
        let model = model()
        model.guildOnboardings[guildID] = GuildOnboarding(
            guildID: guildID,
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(
                    id: 1,
                    title: "Region",
                    options: [
                        GuildOnboarding.Option(id: 2, title: "Europe"),
                        GuildOnboarding.Option(id: 3, title: "Asia"),
                    ],
                    isSingleSelect: true
                )
            ],
            responses: [2]
        )
        model.toggleOnboardingOption(3, inPrompt: 1)
        #expect(model.guildOnboardings[guildID]?.responses == [3])
    }

    // MARK: Following

    /// **The controls exist only where the server has opt-in channels**, which
    /// is what onboarding being enabled means. A plain server's channel list is
    /// not something anybody opts into, and a checkbox there would be a control
    /// writing a flag with no effect.
    @Test("A server with no onboarding offers no follow controls")
    func followingNeedsOnboarding() throws {
        let model = model()
        #expect(try #require(model.channelsAndRolesPresentation).offersFollowing == false)

        model.guildOnboardings[guildID] = GuildOnboarding(guildID: guildID, isEnabled: true)
        #expect(try #require(model.channelsAndRolesPresentation).offersFollowing)
    }

    /// **A followed category carries its channels.** Following a category is
    /// "show me this section", so every channel in it is in — and its own tick
    /// is shown *locked*, because the channel's override is not what is
    /// deciding and a control that looks like it decides is unpredictable.
    @Test("A followed category ticks its channels and takes their tick away")
    func followedCategoryCarriesItsChannels() throws {
        let model = model()
        var index = ChannelIndex()
        let categoryID = ChannelID(rawValue: 3000)
        index.replaceChannels(
            [
                Channel(id: categoryID, kind: .category, guildID: guildID, name: "INFO", position: 0),
                Channel(
                    id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID,
                    name: "rules", parentID: categoryID, position: 1
                ),
                Channel(
                    id: ChannelID(rawValue: 2002), kind: .text, guildID: guildID,
                    name: "faq", parentID: categoryID, position: 2
                ),
            ],
            inGuild: guildID
        )
        model.channelIndex = index
        model.guildOnboardings[guildID] = GuildOnboarding(guildID: guildID, isEnabled: true)
        model.followedChannelIDs = [categoryID, ChannelID(rawValue: 2001)]
        model.followsInFlight = [ChannelID(rawValue: 2002)]

        let followed = try #require(model.channelsAndRolesPresentation?.categories.first)
        #expect(followed.channelID == categoryID)
        #expect(followed.isFollowed)
        // Both are in, and neither tick is the channel's own to press — even the
        // one that also carries an override of its own.
        let allIn = followed.channels.allSatisfy(\.isFollowed)
        let allLocked = followed.channels.allSatisfy(\.isFollowLocked)
        #expect(allIn)
        #expect(allLocked)
        #expect(followed.channels[1].isFollowWorking)

        // With the category unfollowed, each channel answers for itself again.
        model.followedChannelIDs = [ChannelID(rawValue: 2001)]
        let free = try #require(model.channelsAndRolesPresentation?.categories.first)
        #expect(!free.isFollowed)
        #expect(free.channels[0].isFollowed)
        #expect(!free.channels[0].isFollowLocked)
        #expect(!free.channels[1].isFollowed)
    }

    // MARK: The channel list follows the follows

    /// The reader's own Show All Channels switch, turned off: what filters a
    /// list in Discord (`OPT_IN_CHANNELS_ON`), and so here.
    private func optIn(_ model: AppModel) {
        model.guildUserSettings[guildID] = GuildUserSettings(
            guildID: guildID, flags: GuildUserSettingsFlags.optInChannelsOn
        )
    }

    /// **The filter only ever narrows a server the reader demonstrably uses it
    /// on.** An account that has never opted into anything has an *unknown*
    /// state rather than an empty one, and filtering there would hide every
    /// channel in the server.
    @Test("A server the reader has never opted into shows every channel")
    func noFollowsMeansNoFiltering() throws {
        let model = model()
        optIn(model)
        #expect(!model.hidesUnfollowedChannels(inGuild: guildID))
        let channelRows = model.sidebarPresentation.rows.filter(\.isChannel)
        #expect(channelRows.count == 2)
    }

    /// **WC-6RZS, #8.** Discord opts members into a server's default channels
    /// without turning the filter on, so a server with onboarding and a few
    /// follows is still a whole server until the reader turns Show All Channels
    /// off. Filtering on the onboarding showed Ubiquiti as one channel.
    @Test("Onboarding and follows filter nothing while Show All Channels is on")
    func followsAloneDoNotFilter() {
        let model = model()
        model.guildOnboardings[guildID] = GuildOnboarding(guildID: guildID, isEnabled: true)
        model.followedChannelIDs = [ChannelID(rawValue: 2001)]
        #expect(!model.hidesUnfollowedChannels(inGuild: guildID))
        let names = model.sidebarPresentation.rows.compactMap(\.channelName)
        #expect(names.sorted() == ["faq", "general"])
    }

    /// The switch alone decides: the onboarding is loaded only when a server is
    /// opened, and the list (and its server's light) must not change when it is.
    @Test("Show All Channels off filters whether or not the onboarding is loaded")
    func theSwitchDecides() {
        let model = model()
        optIn(model)
        model.followedChannelIDs = [ChannelID(rawValue: 2001)]
        #expect(model.hidesUnfollowedChannels(inGuild: guildID))
        model.guildOnboardings[guildID] = GuildOnboarding(guildID: guildID, isEnabled: false)
        #expect(model.hidesUnfollowedChannels(inGuild: guildID))
    }

    /// The whole point: an unfollowed channel leaves the list.
    @Test("An unfollowed channel is taken out of the channel list")
    func unfollowedChannelLeavesTheList() {
        let model = model()
        optIn(model)
        model.followedChannelIDs = [ChannelID(rawValue: 2001)]
        #expect(model.hidesUnfollowedChannels(inGuild: guildID))

        let names = model.sidebarPresentation.rows.compactMap(\.channelName)
        #expect(names == ["general"])
    }

    /// Discord keeps an unfollowed channel in an opted-in list while it
    /// mentions the reader (`eN`), and its server keeps the light.
    @Test("A channel that mentions the reader stays in an opted-in list")
    func mentionKeepsAnUnfollowedChannel() {
        let model = model()
        optIn(model)
        model.followedChannelIDs = [ChannelID(rawValue: 2001)]
        model.readStates[ChannelID(rawValue: 2002)] = ReadState(mentionCount: 1)
        let names = model.sidebarPresentation.rows.compactMap(\.channelName)
        #expect(names.sorted() == ["faq", "general"])
    }

    /// **#16.** A channel the reader took out of their list cannot light its
    /// server: the dot is a promise the list keeps.
    @Test("A hidden channel's new messages do not light its server")
    func hiddenChannelDoesNotLightTheServer() {
        let model = model()
        optIn(model)
        model.followedChannelIDs = [ChannelID(rawValue: 2001)]
        var index = model.channelIndex
        index.upsert(Channel(
            id: ChannelID(rawValue: 2002), kind: .text, guildID: guildID, name: "faq",
            position: 1, lastMessageID: MessageID(rawValue: 9_000)
        ))
        model.channelIndex = index
        model.readStates[ChannelID(rawValue: 2002)] = ReadState(lastAcknowledgedID: MessageID(rawValue: 1))
        #expect(!model.guildBadge(for: guildID).unread)

        // Show All Channels back on: the channel is in the list, and lights it.
        model.guildUserSettings[guildID] = GuildUserSettings(guildID: guildID)
        #expect(model.guildBadge(for: guildID).unread)
    }

    /// A followed category carries its channels here too — the list and the
    /// browse page read one predicate.
    @Test("A followed category keeps its channels in the list")
    func followedCategoryKeepsItsChannels() {
        let model = model()
        var index = ChannelIndex()
        let categoryID = ChannelID(rawValue: 3000)
        index.replaceChannels(
            [
                Channel(id: categoryID, kind: .category, guildID: guildID, name: "INFO", position: 0),
                Channel(
                    id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID,
                    name: "rules", parentID: categoryID, position: 1
                ),
                Channel(
                    id: ChannelID(rawValue: 2002), kind: .text, guildID: guildID,
                    name: "loose", position: 2
                ),
            ],
            inGuild: guildID
        )
        model.channelIndex = index
        optIn(model)
        model.followedChannelIDs = [categoryID]

        let names = model.sidebarPresentation.rows.compactMap(\.channelName)
        // The category's own channel is in; the loose one, which no category
        // covers and which carries no override, is not.
        #expect(names == ["rules"])
    }

    /// Browse Channels can open a channel the reader has opted out of, and a
    /// list with nothing lit while its transcript is on screen reads as the
    /// selection having been lost.
    @Test("The selected channel stays in the list even when unfollowed")
    func selectedChannelSurvivesTheFilter() {
        let model = model()
        optIn(model)
        model.followedChannelIDs = [ChannelID(rawValue: 2001)]
        model.selectChannel(ChannelID(rawValue: 2002))

        let names = model.sidebarPresentation.rows.compactMap(\.channelName)
        #expect(names.sorted() == ["faq", "general"])
    }

    /// The loose rows above the first category belong to no category, so there
    /// is nothing there to follow and no switch is offered.
    @Test("The uncategorised group has no category to follow")
    func looseGroupHasNoFollowTarget() throws {
        let model = model()
        model.guildOnboardings[guildID] = GuildOnboarding(guildID: guildID, isEnabled: true)
        let group = try #require(model.channelsAndRolesPresentation?.categories.first)
        #expect(group.title == nil)
        #expect(group.channelID == nil)
        #expect(!group.isFollowed)
    }

    /// The set is flat and spans every server, so a row has to read its own
    /// membership rather than a per-guild table.
    @Test("Following one channel leaves every other server's follows alone")
    func followsAreScopedByChannelNotGuild() {
        let model = model()
        let elsewhere = ChannelID(rawValue: 9_001)
        model.followedChannelIDs = [elsewhere]
        model.toggleChannelFollowed(ChannelID(rawValue: 2001))
        // The optimistic write adds one and touches nothing else.
        #expect(model.followedChannelIDs.contains(ChannelID(rawValue: 2001)))
        #expect(model.followedChannelIDs.contains(elsewhere))
    }

    // MARK: The rules

    /// **"Read the rules" goes to the rules channel**, like every other row in
    /// that list — the guide's job is to point at rooms.
    @Test("The rules row leads to the rules channel")
    func rulesRowLeadsToTheChannel() throws {
        let model = model()
        let rulesChannel = ChannelID(rawValue: 2002)
        model.guilds[guildID]?.rulesChannelID = rulesChannel
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            resources: [
                ServerGuide.Resource(id: 0, channelID: ChannelID(rawValue: 2001), title: "Links")
            ]
        )
        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID, rules: ["Be kind."], version: "v1"
        )

        let page = try #require(model.serverGuidePresentation)
        #expect(page.hasRules)
        #expect(page.rulesChannelName == "faq")

        model.openSurface(.serverGuide)
        model.openServerRules(inGuild: guildID)
        #expect(model.selectedChannelID == rulesChannel)
        #expect(model.serverRulesGuildID == nil)
    }

    /// The fallback: rules with no channel to read them in. The row still has
    /// somewhere to go, and the missing destination line says which it is.
    @Test("A server with rules and no rules channel opens the sheet instead")
    func rulesWithoutAChannelOpenTheSheet() throws {
        let model = model()
        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID, rules: ["Be kind."]
        )
        model.openServerRules(inGuild: guildID)
        #expect(model.serverRulesGuildID == guildID)
        #expect(try #require(model.serverGuidePresentation).rulesChannelName == nil)
    }

    /// **A reader who still has to agree gets the sheet, not the channel.** The
    /// channel is where the rules are written; the sheet is where they can be
    /// accepted, and reading is not the thing they are missing.
    @Test("A pending member is taken to the agreement, not to the channel")
    func pendingMemberGetsTheSheet() throws {
        let model = model()
        model.guilds[guildID]?.rulesChannelID = ChannelID(rawValue: 2002)
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: [], isPending: true)
        ]
        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID, rules: ["Be kind."], version: "v1"
        )

        #expect(model.isPendingMember(inGuild: guildID))
        model.openServerRules(inGuild: guildID)
        #expect(model.serverRulesGuildID == guildID)
        #expect(model.selectedChannelID == nil)
        #expect(try #require(model.serverRulesPresentation).canAgree)
    }

    /// **Absent means agreed.** READY carries the reader's own member record for
    /// every guild, so a missing one is a guild still arriving rather than a
    /// gate — defaulting the other way puts a rules banner on every server for
    /// the first second of every launch.
    @Test("A server whose member record has not arrived is not treated as a gate")
    func missingMemberIsNotPending() {
        let model = model()
        #expect(!model.isPendingMember(inGuild: guildID))
    }

    /// Somebody who agreed when they joined is in. A second agreement is a
    /// control with nothing behind it.
    @Test("A full member is offered the rules to read, not to accept")
    func fullMemberCannotAgreeAgain() throws {
        let model = model()
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: [], isPending: false)
        ]
        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID, rules: ["Be kind."], version: "v1"
        )
        model.serverRulesGuildID = guildID
        #expect(try #require(model.serverRulesPresentation).canAgree == false)
    }

    // MARK: My Profile

    /// **The aside is a preview of the answers, not a report of them.** A role
    /// granted by an option just chosen is in the list before the gateway has
    /// said so — the write is already out, and a card promising "how you'll
    /// look" that caught up a round trip later is answering a different
    /// question.
    @Test("The profile merges roles held with roles the current answers grant")
    func selfMergesHeldAndGrantedRoles() throws {
        let model = model()
        let held = RoleID(rawValue: 4001)
        let granted = RoleID(rawValue: 4002)
        let everyone = RoleID(rawValue: guildID.rawValue)
        model.roles[guildID] = [
            everyone: Role(id: everyone, name: "@everyone", position: 0),
            held: Role(id: held, name: "Main Dev", colorValue: 0xE67E22, position: 5),
            granted: Role(id: granted, name: "Europe", colorValue: 0x5865F2, position: 3),
        ]
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: [everyone, held])
        ]
        model.users[readerID] = User(
            id: readerID,
            username: "alex",
            displayName: "alex",
            discriminator: "0",
            decoration: UserDecoration(bio: "sometimes dev")
        )
        model.guildOnboardings[guildID] = GuildOnboarding(
            guildID: guildID,
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(
                    id: 1,
                    title: "Region",
                    options: [
                        // Grants a role they do not hold…
                        GuildOnboarding.Option(id: 2, title: "Europe", roleIDs: [granted]),
                        // …and one they already do, which must not appear twice.
                        GuildOnboarding.Option(id: 3, title: "Dev", roleIDs: [held]),
                        GuildOnboarding.Option(id: 4, title: "Unchosen", roleIDs: [
                            RoleID(rawValue: 4003)
                        ]),
                    ]
                )
            ],
            responses: [2, 3]
        )

        let me = try #require(model.channelsAndRolesPresentation?.me)
        #expect(me.name == "alex")
        #expect(me.bio == "sometimes dev")
        // Seniority order, `@everyone` dropped, no duplicates, and the role from
        // the option nobody chose is absent.
        #expect(me.roles.map(\.name) == ["Main Dev", "Europe"])
        #expect(me.roles[0].colorValue == 0xE67E22)
    }

    /// A nickname stands in front of the account's name rather than replacing
    /// it — the same rule the profile card is built on.
    @Test("A nickname is shown with the account name under it")
    func nicknameKeepsTheAccountName() throws {
        let model = model()
        model.users[readerID] = User(
            id: readerID, username: "alex", displayName: "alex", discriminator: "0"
        )
        model.members[guildID] = [
            readerID: Member(userID: readerID, nickname: "the violet one", roleIDs: [])
        ]
        let me = try #require(model.channelsAndRolesPresentation?.me)
        #expect(me.name == "the violet one")
        #expect(me.accountName == "alex")
    }

    /// Real during bootstrap: the page exists before the account does, and a
    /// card drawn empty says the same thing as a card drawn broken.
    @Test("There is no profile card before the account has arrived")
    func noSelfBeforeTheAccount() throws {
        let model = model()
        model.currentUserID = nil
        #expect(try #require(model.channelsAndRolesPresentation).me == nil)
    }

    // MARK: The preview column

    /// **A resource is read beside the page, not instead of it.** Following one
    /// by replacing the guide loses the list of the other four, which is most of
    /// what a guide is for.
    @Test("A previewed channel takes the supplementary column and leaves the page")
    func previewSitsBesideThePage() {
        let model = model()
        model.selectedChannelID = ChannelID(rawValue: 2001)
        model.openSurface(.serverGuide)
        model.previewChannel(ChannelID(rawValue: 2002))

        let presentation = model.workspacePresentation
        #expect(presentation.primary == .guildSurface(guildID, .serverGuide))
        #expect(presentation.supplementary == .channelPreview(ChannelID(rawValue: 2002)))
        // The conversation the reader will return to is untouched.
        #expect(model.selectedChannelID == ChannelID(rawValue: 2001))
    }

    /// A second press on the row already showing is a close, which is what every
    /// disclosure in this app does.
    @Test("Previewing the open channel again closes it")
    func previewTogglesShut() {
        let model = model()
        model.openSurface(.serverGuide)
        model.previewChannel(ChannelID(rawValue: 2002))
        model.previewChannel(ChannelID(rawValue: 2002))
        #expect(model.previewedChannelID == nil)
    }

    /// The same gate every other way into a channel takes. A guide can name a
    /// channel the reader may not see.
    @Test("A channel the reader cannot open cannot be previewed either")
    func previewRespectsPermissions() {
        let model = model()
        model.openSurface(.serverGuide)
        model.previewChannel(ChannelID(rawValue: 9999))
        #expect(model.previewedChannelID == nil)
    }

    /// A preview belongs to the page that raised it.
    @Test("Leaving the page takes its preview with it")
    func previewDoesNotOutliveThePage() {
        let model = model()
        model.openSurface(.serverGuide)
        model.previewChannel(ChannelID(rawValue: 2002))

        model.openSurface(.gameServers)
        #expect(model.previewedChannelID == nil)

        model.openSurface(.serverGuide)
        model.previewChannel(ChannelID(rawValue: 2002))
        model.selectChannel(ChannelID(rawValue: 2001))
        #expect(model.previewedChannelID == nil)

        model.openSurface(.serverGuide)
        model.previewChannel(ChannelID(rawValue: 2002))
        model.selectGuild(nil)
        #expect(model.previewedChannelID == nil)
    }

    @Test("The preview header names the channel it is showing")
    func previewChromeNamesTheChannel() {
        let model = model()
        let chrome = model.channelPreviewChrome(for: ChannelID(rawValue: 2002))
        #expect(chrome.name == "faq")
        #expect(chrome.symbolName == ChannelKind.text.symbolName)
    }

    // MARK: The guide's rows

    /// A guide can name a channel the reader may not see. The row then leads
    /// nowhere, and it says so rather than looking pressable.
    @Test("A guide row for an unreachable channel names no destination")
    func unreachableGuideRow() throws {
        let model = model()
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            actions: [
                ServerGuide.Action(
                    id: 0,
                    channelID: ChannelID(rawValue: 2001),
                    kind: .read,
                    title: "Read the intro"
                ),
                ServerGuide.Action(
                    id: 1,
                    // A channel no index knows about — which is what a private
                    // one looks like from here.
                    channelID: ChannelID(rawValue: 9999),
                    kind: .read,
                    title: "Somewhere private"
                ),
            ]
        )
        let page = try #require(model.serverGuidePresentation)
        #expect(page.actions[0].channelName == "general")
        #expect(page.actions[1].channelName == nil)
        #expect(page.hasContent)
        #expect(!page.hasRules)
    }

    /// The rules row exists only when there are rules, and the sheet cannot open
    /// onto an empty list.
    @Test("Rules give the guide a row, and an empty set does not")
    func rulesRow() throws {
        let model = model()
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            resources: [ServerGuide.Resource(id: 0, channelID: ChannelID(rawValue: 2001), title: "Links")]
        )
        model.memberVerifications[guildID] = MemberVerification(guildID: guildID)
        #expect(try #require(model.serverGuidePresentation).hasRules == false)

        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID,
            rules: ["Be kind."]
        )
        #expect(try #require(model.serverGuidePresentation).hasRules)

        model.serverRulesGuildID = guildID
        let sheet = try #require(model.serverRulesPresentation)
        #expect(sheet.rules.count == 1)
        // No version on the fixture, and the reader is not pending: two separate
        // reasons the agreement cannot be sent, and either alone is enough.
        #expect(!sheet.canAgree)
    }
}


private extension SidebarRow {
    var isChannel: Bool {
        if case .channel = self { return true }
        return false
    }

    var channelName: String? {
        guard case .channel(let channel) = self else { return nil }
        return channel.name
    }
}

/// Who may open a server's settings window.
///
/// **The gate was derived from the pages and that was wrong twice over.** The
/// Invites page asks for `CREATE_INSTANT_INVITE`, which `@everyone` holds on
/// almost every server — so "is any page reachable" was true for every member of
/// every server, and Server Settings appeared in the menu of servers the reader
/// had no business configuring. Discord's own gate is a ten-permission mask,
/// lifted from its bundle; `createInvite` and `kickMembers` are not in it.
@Suite("Server settings access")
@MainActor
struct ServerSettingsAccessTests {

    @Test("A plain member cannot open it, however many invites they may create")
    func plainMemberIsRefused() {
        let member: Permissions = [
            .createInvite, .viewChannel, .sendMessages, .readMessageHistory,
            .addReactions, .attachFiles, .embedLinks, .useExternalEmojis,
        ]
        #expect(ServerSettingsSection.reachable(with: member).isEmpty)
    }

    @Test("Someone who manages the server gets the whole window")
    func managerGetsEverything() {
        let pages = ServerSettingsSection.reachable(with: .manageGuild)
        #expect(!pages.isEmpty)
        #expect(pages.contains(.profile))
    }

    @Test("An administrator gets every page, whatever else they hold")
    func administratorGetsEverything() {
        let pages = ServerSettingsSection.reachable(with: .administrator)
        #expect(pages.count == ServerSettingsSection.groups.flatMap(\.sections).count)
    }

    /// A moderator holding one of the ten gets a window — with the pages that
    /// permission reaches and nothing else. That is Discord's behaviour and the
    /// reason the gate is a mask rather than `MANAGE_GUILD` alone.
    ///
    /// **Discord's per-page predicates, not one bit each**: Manage Roles also
    /// reaches Members (the moderator mask), and View Audit Log also reaches
    /// Bans (`canManageBans || canViewAuditLog`).
    @Test("One moderation permission opens a window of just its own pages")
    func moderatorGetsTheirOwnPages() {
        let pages = ServerSettingsSection.reachable(with: .manageRoles)
        #expect(pages == [.members, .roles])

        let auditor = ServerSettingsSection.reachable(with: .viewAuditLog)
        #expect(auditor == [.auditLog, .bans])
    }

    /// Invites asked for Create Invite, which `@everyone` holds — so anybody who
    /// could open the window for any other reason found the Invites page too.
    @Test("Invites needs Manage Server, not Create Invite")
    func invitesNeedManageServer() {
        #expect(!ServerSettingsSection.invites.isReachable(with: [.createInvite, .manageRoles]))
        #expect(ServerSettingsSection.invites.isReachable(with: .manageGuild))
    }

    @Test("Integrations opens for Manage Server or Manage Webhooks")
    func integrationsEither() {
        #expect(ServerSettingsSection.integrations.isReachable(with: .manageGuild))
        #expect(ServerSettingsSection.integrations.isReachable(with: .manageWebhooks))
    }

    @Test("Creating expressions alone reaches the three expression pages")
    func createExpressionsReachesExpressions() {
        let pages = ServerSettingsSection.reachable(with: .createExpressions)
        #expect(pages == [.emoji, .stickers, .soundboard])
    }

    /// Kicking is not on the mask: Discord gates its Members page separately.
    @Test("Kicking alone does not open the window")
    func kickAloneIsRefused() {
        #expect(ServerSettingsSection.reachable(with: .kickMembers).isEmpty)
    }

    /// The pages with no requirement of their own are the ones that presume
    /// `MANAGE_GUILD`, and they must not come along with a lesser permission.
    @Test("A page with no requirement of its own still needs MANAGE_GUILD")
    func unrequiredPagesStillNeedManageGuild() {
        #expect(ServerSettingsSection.profile.isReachable(with: .manageRoles) == false)
        #expect(ServerSettingsSection.profile.isReachable(with: .manageGuild))
    }
}
