import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The line under a name in the member list — Discord's `ActivityStatus` —
/// tested through the projection the canvas reads, never the helper (§2).
@MainActor
@Suite("Member list lines")
struct MemberListLineTests {

    private let reader = UserID(rawValue: 1)
    private let player = UserID(rawValue: 2)
    private let here = GuildID(rawValue: 100)
    private let elsewhere = GuildID(rawValue: 200)
    private let general = ChannelID(rawValue: 101)
    private let lounge = ChannelID(rawValue: 102)
    private let otherLounge = ChannelID(rawValue: 201)

    /// Two servers, each with `@everyone` allowed to see and join, and the
    /// reader looking at `#general` in the first.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        model.users[reader] = User(id: reader, username: "alex")
        model.users[player] = User(id: player, username: "rowan")
        let owner = UserID(rawValue: 9)
        model.guilds = [
            here: Guild(id: here, name: "Here", ownerID: owner),
            elsewhere: Guild(id: elsewhere, name: "Elsewhere", ownerID: owner),
        ]
        for guild in [here, elsewhere] {
            let everyone = RoleID(rawValue: guild.rawValue)
            model.roles[guild] = [
                everyone: Role(
                    id: everyone, name: "@everyone", position: 0,
                    permissions: [.viewChannel, .connect]
                ),
            ]
        }
        model.members[here] = [
            reader: Member(userID: reader, roleIDs: []),
            player: Member(userID: player, roleIDs: []),
        ]
        model.members[elsewhere] = [reader: Member(userID: reader, roleIDs: [])]
        // The list the server sends for `#general`: both of them, online.
        var list = MemberList()
        list.apply(
            [.sync(start: 0, rows: [.group(.online), .member(reader), .member(player)])],
            groups: [MemberList.Group(id: .online, count: 2)]
        )
        model.memberLists[MemberListKey(guildID: here, listID: "everyone")] = list
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: general, kind: .text, guildID: here, name: "general"),
                Channel(id: lounge, kind: .voice, guildID: here, name: "Lounge"),
            ],
            inGuild: here
        )
        index.replaceChannels(
            [Channel(id: otherLounge, kind: .voice, guildID: elsewhere, name: "Other")],
            inGuild: elsewhere
        )
        model.channelIndex = index
        model.selectedGuildID = here
        model.selectedChannelID = general
        model.presences[player] = Presence(userID: player, status: .online)
        return model
    }

    private func line(_ model: AppModel) -> MemberRowLine? {
        model.roster.members.values.first { $0.userID == self.player }?.line
    }

    /// **Discord's friends sidebar, through the real roster**: a game takes the
    /// line, and the custom status beside it says nothing (`tT`, `763349`). It's
    /// the direct-message list's line that says both.
    @Test("A game and a custom status: the game, and how long")
    func activityAndStatus() {
        let model = model()
        model.presences[player] = Presence(
            userID: player,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(kind: .custom, name: "Custom Status", state: "brb", emoji: EmojiRef(name: "☕️")),
                Activity(kind: .playing, name: "Counter-Strike 2", startedAt: Date.now.addingTimeInterval(-7_200)),
            ])
        )
        let line = line(model)
        #expect(line?.glyph == .game)
        #expect(line?.text == "Counter-Strike 2")
        #expect(line?.emoji == nil)
        #expect(line?.since != nil)
        #expect(line?.isLive == true)
    }

    @Test("Somebody talking in a room the reader can see is 'In voice'")
    func inVoice() {
        let model = model()
        model.voiceStates[player] = VoiceState(userID: player, channelID: lounge, guildID: here)
        #expect(line(model)?.glyph == .voice)
        #expect(line(model)?.text == "In voice")
    }

    @Test("Offline is no line, whatever else is true")
    func offlineIsNoLine() {
        let model = model()
        model.presences[player] = Presence(
            userID: player,
            status: .offline,
            activities: PresenceActivities(list: [Activity(kind: .playing, name: "Counter-Strike 2")])
        )
        model.voiceStates[player] = VoiceState(userID: player, channelID: lounge, guildID: here)
        #expect(line(model) == nil)
    }

    /// **Why the key carries facts rather than `voiceRevision`**: a call in
    /// another server must not rebuild a roster of five hundred.
    @Test("A call in another server does not rebuild the list")
    func otherServersCallsKeepTheMemo() {
        let model = model()
        _ = model.roster
        let before = model.rosterCache?.key
        model.voiceStates[UserID(rawValue: 50)] = VoiceState(
            userID: UserID(rawValue: 50), channelID: otherLounge, guildID: elsewhere
        )
        model.voiceRevision &+= 1
        _ = model.roster
        // The same key: the memo answered and nothing was rebuilt.
        #expect(model.rosterCache?.key == before)

        model.voiceStates[player] = VoiceState(userID: player, channelID: lounge, guildID: here)
        #expect(line(model)?.text == "In voice")
    }
}

/// A row's facts through the real roster: what the painter is handed.
@MainActor
@Suite("Member list rows")
struct MemberListRowFactsTests {
    private let reader = UserID(rawValue: 1)
    private let player = UserID(rawValue: 2)
    private let here = GuildID(rawValue: 100)
    private let general = ChannelID(rawValue: 101)
    private let lounge = ChannelID(rawValue: 102)
    private let game = ApplicationID(rawValue: 500)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        model.users[reader] = User(id: reader, username: "alex")
        model.users[player] = User(id: player, username: "rowan")
        model.guilds = [here: Guild(id: here, name: "Here", ownerID: UserID(rawValue: 9))]
        let everyone = RoleID(rawValue: here.rawValue)
        model.roles[here] = [
            everyone: Role(id: everyone, name: "@everyone", position: 0, permissions: [.viewChannel, .connect]),
        ]
        model.members[here] = [
            reader: Member(userID: reader, roleIDs: []),
            player: Member(userID: player, roleIDs: []),
        ]
        var list = MemberList()
        list.apply(
            [.sync(start: 0, rows: [.group(.online), .member(reader), .member(player)])],
            groups: [MemberList.Group(id: .online, count: 2)]
        )
        model.memberLists[MemberListKey(guildID: here, listID: "everyone")] = list
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: general, kind: .text, guildID: here, name: "general"),
                Channel(id: lounge, kind: .voice, guildID: here, name: "Lounge"),
            ],
            inGuild: here
        )
        model.channelIndex = index
        model.selectedGuildID = here
        model.selectedChannelID = general
        model.presences[player] = Presence(userID: player, status: .online)
        model.presences[reader] = Presence(userID: reader, status: .online)
        return model
    }

    private func row(_ model: AppModel, _ userID: UserID? = nil) -> MemberEntry? {
        let wanted = userID ?? player
        return model.roster.members.values.first { $0.userID == wanted }
    }

    /// `AppSettings` is shared, so every test here says what it wants.
    private func organized(_ organization: MemberListOrganization, _ body: () throws -> Void) async rethrows {
        try await withAppSettings(
            \.memberListOrganization, \.collapsedMemberSections, \.groupsMembersInVoice
        ) { settings in
            settings.memberListOrganization = organization
            settings.collapsedMemberSections = [:]
            try body()
        }
    }

    private func playing(_ model: AppModel, key: String? = "mp:external/abc/https/x.png") {
        model.presences[player] = Presence(
            userID: player,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(
                    kind: .playing, name: "Escape from Tarkov", applicationID: game,
                    largeImageKey: key, startedAt: Date.now.addingTimeInterval(-7_200)
                ),
            ])
        )
    }

    @Test("A game with its own picture puts it on the row and makes them active")
    func gameArt() {
        let model = model()
        playing(model)
        let row = row(model)
        guard case .image(let url)? = row?.art else {
            Issue.record("the row should have the game's picture")
            return
        }
        #expect(url.absoluteString.contains("external/abc"))
        #expect(row?.liveGame?.key == "500")
        #expect(row?.isActiveNow == true)
    }

    /// Discord's `tD`: the application's icon, once it's known.
    @Test("A game with no picture waits on its application, then shows its icon")
    func applicationIcon() {
        let model = model()
        playing(model, key: nil)
        #expect(row(model)?.art == .placeholder(.game))
    }

    @Test("A game with no application earns the line and no picture")
    func noApplication() {
        let model = model()
        model.presences[player] = Presence(
            userID: player, status: .online,
            activities: PresenceActivities(list: [Activity(kind: .playing, name: "Xcode")])
        )
        #expect(row(model)?.line?.text == "Xcode")
        #expect(row(model)?.art == nil)
    }

    @Test("Listening shows what's playing, and isn't active")
    func listening() {
        let model = model()
        model.presences[player] = Presence(
            userID: player, status: .online,
            activities: PresenceActivities(list: [
                Activity(
                    kind: .listening, name: "Spotify", state: "Devon Hendryx",
                    largeImageKey: "spotify:abc", partyID: "spotify:1"
                ),
            ])
        )
        let row = row(model)
        guard case .image(let url)? = row?.art else {
            Issue.record("the row should have the album's picture")
            return
        }
        #expect(url.host() == "i.scdn.co")
        #expect(row?.isActiveNow == false)
    }

    @Test("An app's game isn't a game")
    func botsDontPlay() {
        let model = model()
        model.users[player] = User(id: player, username: "bot", isBot: true)
        playing(model)
        let row = row(model)
        #expect(row?.liveGame == nil)
        #expect(row?.art == nil)
        #expect(row?.isActiveNow == false)
        #expect(row?.line?.glyph == nil)
    }

    @Test("Join Voice: a room the reader can join and isn't in, and never on their own row")
    func joinable() {
        let model = model()
        model.voiceStates[player] = VoiceState(userID: player, channelID: lounge, guildID: here)
        #expect(row(model)?.joinableVoiceChannelID == lounge)
        #expect(row(model)?.actionCount == 3)

        model.voiceStates[reader] = VoiceState(userID: reader, channelID: lounge, guildID: here)
        #expect(row(model, reader)?.joinableVoiceChannelID == nil)
        #expect(row(model, reader)?.actionCount == 1)
    }

    @Test("Roles has no Active Now; Active Now does, and it's the row's only copy")
    func modes() async {
        let model = model()
        playing(model)
        await organized(.roles) {
            #expect(model.roster.sections.map(\.key) == [.online])
        }
        await organized(.activeNow) {
            model.rosterCache = nil
            #expect(model.roster.sections.map(\.key) == [.activeNow, .online])
            #expect(model.roster.sections.first?.countText == "1")
            #expect(model.roster.members.values.filter { $0.userID == self.player }.count == 1)
        }
    }

    @Test("Somebody in a room with no row, known to be online, joins Active Now")
    func roomCandidates() async {
        let model = model()
        let visitor = UserID(rawValue: 3)
        model.users[visitor] = User(id: visitor, username: "visitor")
        model.members[here]?[visitor] = Member(userID: visitor, roleIDs: [])
        model.voiceStates[visitor] = VoiceState(userID: visitor, channelID: lounge, guildID: here)
        await organized(.activeNow) {
            model.rosterCache = nil
            // A presence nobody has heard yet might be invisible.
            #expect(model.roster.members.values.contains { $0.userID == visitor } == false)
            model.presences[visitor] = Presence(userID: visitor, status: .online)
            model.notePresencesChanged(for: [visitor])
            #expect(model.roster.members.values.contains { $0.userID == visitor })
        }
    }

    @Test("What was folded is remembered per server, and comes back")
    func folding() async {
        let model = model()
        await organized(.roles) {
            model.toggleMemberSection(.online)
            #expect(AppSettings.shared.collapsedMemberSections["guild:100"] == ["online"])
            #expect(model.roster.sections.first?.isCollapsed == true)
            #expect(model.roster.members.isEmpty)
            model.toggleMemberSection(.online)
            #expect(AppSettings.shared.collapsedMemberSections["guild:100"] == nil)
            #expect(model.roster.sections.first?.isCollapsed == false)
        }
    }

    @Test("Search finds by nickname and name, and says how many")
    func search() {
        let model = model()
        model.members[here]?[player] = Member(userID: player, nickname: "Natty", roleIDs: [])
        #expect(model.memberSearchRoster(query: "natt").sections.first?.label == "1 result found")
        #expect(model.memberSearchRoster(query: "rowan").members[1]?.userID == player)
        #expect(model.memberSearchRoster(query: "zzz").sections.isEmpty)
        #expect(model.memberSearchRoster(query: "a").sections.first?.label == "2 results found")
        #expect(model.memberSearchRoster(query: "natt").identity.hasPrefix("search:"))
    }

    @Test("What can be organized: a long list can't be put in letters")
    func capabilities() {
        let model = model()
        #expect(model.memberListCapabilities == MemberListCapabilities(hasRoles: true, isWhole: true))
        var list = MemberList()
        list.apply([], groups: [MemberList.Group(id: .online, count: 500)])
        model.memberLists[MemberListKey(guildID: here, listID: "everyone")] = list
        let capabilities = model.memberListCapabilities
        #expect(!capabilities.isWhole)
        #expect(capabilities.resolved(.alphabetical) == .activeNow)
    }

    @Test("A note shows if the reader takes them, and is the relationship's")
    func notes() {
        let model = model()
        model.relationshipFacts[player] = RelationshipFacts(note: "hey")
        #expect(model.friendRequestNote(of: player) == "hey")
        model.isNSFWAllowed = false
        #expect(model.friendRequestNote(of: player) == nil)
        model.messagingPrivacy.hasFriendRequestNotesSetting = true
        model.messagingPrivacy.showsFriendRequestNotes = true
        #expect(model.friendRequestNote(of: player) == "hey")
        model.messagingPrivacy.showsFriendRequestNotes = false
        model.isNSFWAllowed = true
        #expect(model.friendRequestNote(of: player) == nil)
    }
}
