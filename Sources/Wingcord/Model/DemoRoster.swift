import Foundation
import WingcordCore

// MARK: - The member list, for `--demo`
//
// **Every state a row and a heading can be in, on one screen**, because a roster
// where everyone is online and doing nothing can only ever show the half of it
// that was easy: a game with its own picture, one with only its application's
// icon, one still waiting on it, music, a custom status, a room you could join, an
// app whose "Playing /help" must not read as somebody playing, an offline row with
// a nameplate behind it.
//
// **The Iris Project holds a list it has all of, and Krxqz one it doesn't.** Those
// are the two kinds of list there are: see `MemberList.isWhole`.

extension DemoFixtures {

    static func populateRoster(_ model: AppModel, guildID: GuildID, me: UserID) {
        func who(_ name: String) -> UserID? {
            model.users.values.first { $0.displayName == name && $0.id != me }?.id
        }
        func set(_ name: String, _ status: PresenceStatus, _ activities: [Activity]) {
            guard let userID = who(name) else { return }
            model.presences[userID] = Presence(
                userID: userID, status: status,
                activities: activities.isEmpty ? nil : PresenceActivities(list: activities)
            )
        }
        func ago(_ seconds: TimeInterval) -> Date { Date.now.addingTimeInterval(-seconds) }

        // A game this client knows only by id, with a picture drawn on this Mac:
        // the path through `games` to a row's squircle.
        let tarkov = ApplicationID(rawValue: 700_000_000_000_000_001)
        model.games[tarkov] = Game(
            id: tarkov,
            name: "Escape from Tarkov",
            media: GameMedia(icon: DemoGameArt.tile(
                symbol: "scope", top: (0.36, 0.20, 0.16), bottom: (0.10, 0.12, 0.10), name: "tarkov"
            ).map { .url($0) })
        )

        set("Bram", .doNotDisturb, [
            Activity(kind: .playing, name: "Escape from Tarkov", applicationID: tarkov, startedAt: ago(2 * 3_600 + 240)),
        ])
        // Two in one game, so Game has a section with more than one person in it.
        set("iamnumber7", .online, [
            Activity(kind: .playing, name: "Beat Saber", details: "Expert+", applicationID: beatSaber, startedAt: ago(34 * 60)),
        ])
        set("MarvelMallow", .idle, [
            Activity(kind: .competing, name: "Beat Saber", state: "Ranked", applicationID: beatSaber, startedAt: ago(3_660)),
        ])
        set("rin", .online, [
            Activity(kind: .playing, name: "The Sims 4", details: "Building a house", applicationID: sims, startedAt: ago(3 * 86_400)),
        ])
        // Under the pointer the buttons take this down to a few letters and the
        // time still has to fit: Alex's screenshot 45.
        set("kazume", .online, [
            Activity(
                kind: .playing, name: "The Elder Scrolls V: Skyrim Special Edition",
                applicationID: wuthering, startedAt: ago(52 * 60)
            ),
        ])
        // An application nobody has resolved: the squircle's placeholder.
        set("vale", .online, [
            Activity(
                kind: .playing, name: "Deep Rock Galactic",
                applicationID: ApplicationID(rawValue: 700_000_000_000_000_002), startedAt: ago(9 * 60)
            ),
        ])
        // A game with no application at all earns the line and no picture.
        set("Void", .online, [Activity(kind: .playing, name: "Xcode", startedAt: ago(40))])
        set("Voltcast", .online, [
            Activity(
                kind: .listening, name: "Spotify", state: "Devon Hendryx", details: "God & Earrings",
                largeImageKey: "spotify:ab67616d0000b2737905832361a25be8d74a5c65",
                startedAt: ago(3 * 60), partyID: "spotify:demo"
            ),
        ])
        set("Jay", .online, [
            Activity(kind: .custom, name: "Custom Status", state: "serpent is lord", emoji: EmojiRef(name: "🐍")),
        ])
        set("0xC0FFEE42", .idle, [Activity(kind: .custom, name: "Custom Status", state: "back in 10")])
        // Nobody's playing anything here, whatever the line says.
        set("2lumin0s", .online, [Activity(kind: .playing, name: "/help", startedAt: ago(90_000))])
        // A nameplate behind a dimmed name: the plate stays whole.
        set("Toffee", .offline, [])
        // A plain row, online and doing nothing.
        set("vrm", .online, [])
        set("million", .doNotDisturb, [])
        set("beagle", .idle, [])

        // **A pale profile**, so a profile's flyouts can be seen turning with it:
        // the pink of Alex's image 48.
        if let ray = who("Jay"), let user = model.users[ray] {
            let bioChannel = model.channelIndex.channelIDs(inGuild: guildID).first {
                model.channelIndex[$0]?.kind == .text
            }
            model.users[ray] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: user.avatarHash,
                discriminator: user.discriminator,
                flags: user.flags,
                isBot: user.isBot,
                isSystem: user.isSystem,
                decoration: UserDecoration(
                    nameplate: user.decoration?.nameplate,
                    displayNameStyle: user.decoration?.displayNameStyle,
                    // **One of everything prose can hold**, so selection, spoilers and
                    // what a click does can all be tried in one place.
                    bio: "serpent is **lord**, and this profile is *pink*. "
                        + "Don't tell anyone: ||the serpent is actually a very long noodle "
                        + "and everybody here has known for years||.\n"
                        + "Ask <@\(who("Bram")?.rawValue ?? 0)> or see <#\(bioChannel?.rawValue ?? 0)> "
                        + "or https://example.com/iris or [the guide](https://example.com/guide).\n"
                        + "> quoted, because somebody said it\n"
                        + "Back on <t:1798761600:D>. `inline code` and <:x_shaq:1122960370512957560>, 🐍",
                    themeColorValues: [0xF8_D3_EA, 0xFF_9B_D8],
                    // Nobody's directory answers in `--demo` but the reader's, so
                    // this is a Nitro badge's card before Discord has said anything.
                    badges: [
                        AccountBadge(id: "premium_tenure_12_month_v2", iconHash: nil, label: "Subscriber since Oct 3, 2025"),
                    ],
                    connectedAccounts: user.decoration?.connectedAccounts ?? demoConnections,
                    premiumTier: .nitro,
                    premiumSince: Date.now.addingTimeInterval(-86_400 * 400),
                    primaryGuildTag: "IRIS",
                    primaryGuildID: guildID
                )
            )
        }
        // **And a dark one wearing the same tag**, so its card can be seen turning
        // both ways whichever theme the demo is in.
        if let shin = who("rin"), let user = model.users[shin] {
            model.users[shin] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: user.avatarHash,
                discriminator: user.discriminator,
                flags: user.flags,
                isBot: user.isBot,
                isSystem: user.isSystem,
                decoration: UserDecoration(
                    nameplate: user.decoration?.nameplate,
                    displayNameStyle: user.decoration?.displayNameStyle,
                    themeColorValues: user.decoration?.themeColorValues,
                    premiumTier: .nitro,
                    primaryGuildTag: "IRIS",
                    primaryGuildID: guildID
                )
            )
        }

        // Two rooms here that the reader isn't in, so Join Voice has somewhere to
        // go. **After `populateVoice`**, so the reader's own call stays where it is.
        let rooms = ["vc-lounge", "vc-ranked"].enumerated().map { offset, name in
            let channel = Channel(
                id: ChannelID(rawValue: guildID.rawValue * 1000 + 950 + UInt64(offset)),
                kind: .voice,
                guildID: guildID,
                name: name,
                position: 900 + offset
            )
            model.channelIndex.upsert(channel)
            return channel.id
        }
        func seat(_ name: String, in room: ChannelID, activities: [Activity] = []) {
            guard let userID = who(name) else { return }
            model.voiceStates[userID] = VoiceState(
                userID: userID, channelID: room, guildID: guildID, sessionID: "demo",
                connectedAt: ago(18 * 60)
            )
            model.presences[userID] = Presence(
                userID: userID, status: .online,
                activities: activities.isEmpty ? nil : PresenceActivities(list: activities)
            )
        }
        // In a room and playing: the game only gives the line its clock.
        seat("torriel", in: rooms[0], activities: [
            Activity(kind: .playing, name: "Beat Saber", applicationID: beatSaber, startedAt: ago(47 * 60)),
        ])
        seat("vexlor", in: rooms[0])
        seat("jamesen", in: rooms[0])
        // A person alone in a room stays an ordinary row, with Join Voice on it.
        seat("alegre", in: rooms[1])
        // Somebody in the lounge who isn't on this list, so the group says so.
        let visitor = UserID(rawValue: 69_999)
        model.users[visitor] = User(id: visitor, username: "visitor", displayName: "visitor", discriminator: "0")
        model.voiceStates[visitor] = VoiceState(userID: visitor, channelID: rooms[0], guildID: guildID, sessionID: "demo")
        model.voiceRevision &+= 1

        // More people under the named roles, so a heading has somebody to fold.
        var members = model.members[guildID] ?? [:]
        let hoisted = roleSpecs.indices.map { RoleID(rawValue: 2000 + UInt64($0)) }
        for (name, role) in [("Bram", 2), ("iamnumber7", 2), ("Jay", 2), ("rin", 3), ("Void", 3)] {
            guard let userID = who(name) else { continue }
            members[userID]?.roleIDs = [hoisted[role]]
        }
        model.members[guildID] = members

        // A role icon's three kinds: an upload, an emoji, and neither. The CDN has
        // no role of the demo's to point at, so an upload is a picture drawn here.
        if var roles = model.roles[guildID] {
            roles[hoisted[1]]?.unicodeEmoji = "🛡️"
            // Those rooms can be joined.
            let everyone = RoleID(rawValue: guildID.rawValue)
            roles[everyone]?.permissions.formUnion([.connect, .speak])
            model.roles[guildID] = roles
        }
        model.demoRoleIcons[hoisted[0]] = DemoGameArt.tile(
            symbol: "hammer.fill", top: (0.95, 0.60, 0.20), bottom: (0.80, 0.35, 0.10), name: "role-main-dev"
        )
        model.demoRoleIcons[hoisted[2]] = DemoGameArt.tile(
            symbol: "leaf.fill", top: (0.30, 0.85, 0.50), bottom: (0.10, 0.60, 0.35), name: "role-contributor"
        )
        model.roleRevision &+= 1

        // The list as the server would send it now that all that has changed.
        model.memberLists[MemberListKey(guildID: guildID, listID: "everyone")] = memberList(
            members: members,
            users: model.users,
            presences: model.presences,
            roles: model.roles[guildID] ?? [:]
        )
        model.noteEveryPresenceChanged()
        model.memberListRevision &+= 1

        if let longList = model.guilds.values.first(where: { $0.name.hasPrefix("Krxqz") })?.id {
            populateLongList(model, guildID: longList)
        }
    }

    /// A list too long to hold: the first page of nearly five thousand rows, the
    /// rest placeholders, and the demo has no server to send more. Active Now's
    /// count says `6+` here, because it can only speak for the first page.
    private static func populateLongList(_ model: AppModel, guildID: GuildID) {
        let moderators = RoleID(rawValue: guildID.rawValue * 10 + 1)
        var roles = model.roles[guildID] ?? [:]
        roles[moderators] = Role(id: moderators, name: "Moderators", colorValue: 0x3BA55C, isHoisted: true, position: 5)
        model.roles[guildID] = roles

        let games = [
            ("Beat Saber", beatSaber), ("The Sims 4", sims), ("Arknights: Endfield", endfield),
        ]
        var members = model.members[guildID] ?? [:]
        var rows: [MemberList.Row?] = [.group(.role(moderators))]
        func add(_ offset: Int, roleIDs: [RoleID]) {
            let userID = UserID(rawValue: 70_000 + UInt64(offset))
            model.users[userID] = User(
                id: userID, username: "player\(offset)", displayName: "player \(offset)", discriminator: "0"
            )
            members[userID] = Member(userID: userID, roleIDs: roleIDs)
            let game = games[offset % games.count]
            model.presences[userID] = Presence(
                userID: userID,
                status: offset % 3 == 0 ? .idle : .online,
                activities: offset % 15 == 7
                    ? PresenceActivities(list: [
                        Activity(
                            kind: .playing, name: game.0, applicationID: game.1,
                            startedAt: Date.now.addingTimeInterval(-Double(offset) * 300)
                        ),
                    ])
                    : nil
            )
            rows.append(.member(userID))
        }
        for offset in 0..<12 { add(offset, roleIDs: [moderators]) }
        rows.append(.group(.online))
        for offset in 12..<98 { add(offset, roleIDs: []) }
        model.members[guildID] = members
        var list = MemberList()
        list.apply(
            [.sync(start: 0, rows: rows)],
            groups: [
                MemberList.Group(id: .role(moderators), count: 12),
                MemberList.Group(id: .online, count: 4_812),
            ]
        )
        model.memberLists[MemberListKey(guildID: guildID, listID: "everyone")] = list
    }
}
