import Foundation
import WingcordCore

/// Deterministic fixture data, behind `--demo`.
///
/// Not a "mock mode" the app can fall into by accident: nothing here runs unless
/// the flag is present, and there is no fallback from a failed sign-in to this.
/// A client that quietly shows fabricated servers when the network fails is one
/// nobody can trust.
///
/// It earns its place three times over — it is how the chrome is screenshotted
/// without an account, how the timeline is benchmarked against a known message
/// count, and how a layout regression is reproduced without waiting for a real
/// channel to look the same way twice.
enum DemoFixtures {

    static func populate(_ model: AppModel) {
        model.connectionState = .ready
        model.selfStatus = .online

        var users: [UserID: User] = [:]
        var userIDs: [UserID] = []
        for (offset, name) in names.enumerated() {
            // Real snowflake magnitudes, not 1…27. The default-avatar index is
            // `(id >> 22) % 6`, so small ids all resolve to the same picture and
            // a roster of fixtures looks wrong in a way real accounts never do.
            let id = UserID(rawValue: 900_000_000_000_000_000 + UInt64(offset) * 4_194_304)
            userIDs.append(id)
            users[id] = User(
                id: id,
                username: name.lowercased().replacing(" ", with: ""),
                displayName: name,
                discriminator: "0",
                isBot: offset % 11 == 0 && offset > 0
            )
        }
        let me = userIDs[0]
        model.currentUserID = me
        model.mentionableIDs = [me.rawValue]
        model.users = users

        var guilds: [GuildID: Guild] = [:]
        var folders: [GuildFolder] = []
        var index = ChannelIndex()

        for (offset, spec) in guildSpecs.enumerated() {
            let guildID = GuildID(rawValue: UInt64(1000 + offset))
            guilds[guildID] = Guild(
                id: guildID,
                name: spec.name,
                // A hash, so `SidebarHeader.hasBanner` is true and the banner
                // layout is actually exercised — the flag above used to set
                // nothing but the boost tier, so `--demo` never drew a banner
                // at all and the one arrangement in the chrome with real
                // arithmetic behind it could not be screenshotted without an
                // account. The CDN answers 404 for it, which is the honest
                // outcome for a fabricated guild and leaves the block showing
                // its loading ground: a flat rectangle with measurable edges.
                bannerHash: spec.hasBanner ? "demofixturebanner" : nil,
                ownerID: userIDs[0],
                premiumTier: spec.hasBanner ? 2 : 0,
                features: spec.isCommunity ? ["COMMUNITY"] : [],
                memberCount: spec.memberCount
            )
            index.replaceChannels(
                channels(for: guildID, spec: spec),
                inGuild: guildID
            )
            folders.append(GuildFolder(guildIDs: [guildID]))
        }

        // One real folder, to exercise the grouped path.
        let folderGuilds = Array(guilds.keys.sorted { $0.rawValue < $1.rawValue }.prefix(3))
        folders = [GuildFolder(
            id: 90_001,
            name: "Development",
            colorValue: 0x5865F2,
            guildIDs: folderGuilds
        )] + folders.filter { folder in
            !folder.guildIDs.contains { folderGuilds.contains($0) }
        }

        // Roles, members and presences for the first guild, so the roster
        // canvas — hoist groups, role colours, presence dots, activity lines —
        // is exercised rather than merely present.
        let firstGuild = GuildID(rawValue: 1000)
        let everyoneRole = RoleID(rawValue: firstGuild.rawValue)
        var guildRoles: [RoleID: Role] = [
            everyoneRole: Role(
                id: everyoneRole,
                name: "@everyone",
                position: 0,
                permissions: [.viewChannel, .sendMessages, .readMessageHistory, .addReactions]
            )
        ]
        for (offset, spec) in roleSpecs.enumerated() {
            let id = RoleID(rawValue: 2000 + UInt64(offset))
            guildRoles[id] = Role(
                id: id,
                name: spec.name,
                colorValue: spec.color,
                isHoisted: spec.hoisted,
                position: roleSpecs.count - offset
            )
        }
        model.roles[firstGuild] = guildRoles

        var guildMembers: [UserID: Member] = [:]
        var presences: [UserID: Presence] = [:]
        let hoistIDs = roleSpecs.indices.map { RoleID(rawValue: 2000 + UInt64($0)) }
        for (offset, userID) in userIDs.enumerated() {
            var roleIDs: [RoleID] = []
            if offset < hoistIDs.count { roleIDs.append(hoistIDs[offset]) }
            guildMembers[userID] = Member(
                userID: userID,
                roleIDs: roleIDs,
                joinedAt: Date.now.addingTimeInterval(-Double(offset) * 86_400 * 30)
            )
            let statuses: [PresenceStatus] = [.online, .idle, .doNotDisturb, .online, .offline]
            let status = statuses[offset % statuses.count]
            let activity: Activity? = offset % 4 == 1
                ? Activity(kind: .playing, name: "Xcode")
                : (offset % 7 == 3
                    ? Activity(kind: .custom, name: "Custom Status", state: "shipping it")
                    : nil)
            presences[userID] = Presence(
                userID: userID,
                status: status,
                isOnMobile: offset % 9 == 4,
                activities: activity.map { PresenceActivities(list: [$0]) }
            )
        }
        model.members[firstGuild] = guildMembers
        model.presences = presences

        model.guilds = guilds
        model.folders = folders
        model.channelIndex = index
        model.roleRevision &+= 1
        model.memberRevision &+= 1
        model.presenceRevision &+= 1
        model.railRevision &+= 1
        model.sidebarRevision &+= 1

        // Unread state on a few channels, so the badges and the bolding are
        // visible rather than theoretical.
        var readStates: [ChannelID: ReadState] = [:]
        for (offset, channelID) in index.channelIDs(inGuild: GuildID(rawValue: 1000)).enumerated() {
            guard index[channelID]?.kind.isConversation == true else { continue }
            readStates[channelID] = ReadState(
                lastAcknowledgedID: offset % 3 == 0 ? nil : MessageID(rawValue: .max),
                mentionCount: offset % 5 == 0 ? offset % 7 + 1 : 0,
                isMuted: false
            )
        }
        model.readStates = readStates

        let first = firstGuild
        model.selectedGuildID = first
        model.selectedChannelID = index.channelIDs(inGuild: first).first {
            index[$0]?.kind == .text
        }

        if let channelID = model.selectedChannelID {
            model.setMessages(transcript(in: channelID, users: users), in: channelID)
        }
    }

    // MARK: Shapes

    private struct GuildSpec {
        var name: String
        var hasBanner: Bool
        var isCommunity: Bool
        var memberCount: Int
        var categories: [(String, [String])]
    }

    private static let guildSpecs: [GuildSpec] = [
        GuildSpec(
            name: "The Iris Project",
            hasBanner: true,
            isCommunity: true,
            memberCount: 12_400,
            categories: [
                ("THIS IS IRIS", ["this-is-iris", "faq", "rules"]),
                ("EVENTS", ["iris-releases", "community-news", "devlog", "sus"]),
                ("SUPPORT", ["voxy-screenshot-contest", "help", "bug-reports"]),
            ]
        ),
        GuildSpec(
            name: "Krxqz | Cfgs, Clients and more",
            hasBanner: false,
            isCommunity: false,
            memberCount: 8_120,
            categories: [
                ("LOBBY", ["announcement", "giveaways", "upload", "config-updates"]),
                ("MAIN", ["chat", "media", "anticheat-list", "mate-finder"]),
                ("CONFIGS AND CLIENTS", ["configs", "free-clients", "israeli-client"]),
            ]
        ),
        GuildSpec(
            name: "Wingcord",
            hasBanner: false,
            isCommunity: true,
            memberCount: 419,
            categories: [
                ("INFO", ["announcements", "rules-and-roles", "faq"]),
                ("CHAT", ["general", "referrals", "coding-help", "server-suggestions"]),
                ("DEV", ["suggestions", "bug-reporting"]),
                ("DEV WEBHOOKS", ["github-events", "etfkit-events"]),
            ]
        ),
        GuildSpec(name: "Flux", hasBanner: false, isCommunity: false, memberCount: 640,
                  categories: [("GENERAL", ["general", "off-topic"])]),
        GuildSpec(name: "Apple Devs", hasBanner: false, isCommunity: false, memberCount: 2_100,
                  categories: [("SWIFT", ["swiftui", "concurrency", "showcase"])]),
        GuildSpec(name: "Cosmic", hasBanner: false, isCommunity: false, memberCount: 88,
                  categories: [("HOME", ["lobby"])]),
    ]

    private static func channels(for guildID: GuildID, spec: GuildSpec) -> [Channel] {
        var result: [Channel] = []
        var position = 0
        var serial: UInt64 = 0

        for (categoryName, channelNames) in spec.categories {
            serial += 1
            let categoryID = ChannelID(rawValue: guildID.rawValue * 1000 + serial)
            result.append(Channel(
                id: categoryID,
                kind: .category,
                guildID: guildID,
                name: categoryName,
                position: position
            ))
            position += 1

            for name in channelNames {
                serial += 1
                result.append(Channel(
                    id: ChannelID(rawValue: guildID.rawValue * 1000 + serial),
                    kind: name.contains("vc") || name == "lobby" ? .voice : .text,
                    guildID: guildID,
                    name: name,
                    parentID: categoryID,
                    position: position,
                    lastMessageID: MessageID(rawValue: 8_000_000 + serial)
                ))
                position += 1
            }
        }
        return result
    }

    /// A transcript with runs, day gaps, replies and a system event, so the
    /// reducer's every branch is visible on screen rather than only in a test.
    private static func transcript(in channelID: ChannelID, users: [UserID: User]) -> MessageBox {
        var box = MessageBox()
        var messages: [Message] = []
        let userIDs = users.keys.sorted { $0.rawValue < $1.rawValue }
        // Start two days back so the day separators have something to separate.
        var moment = Date.now.addingTimeInterval(-2 * 24 * 60 * 60)

        for index in 0..<220 {
            // Runs of two to four from one person, then a gap.
            let author = userIDs[(index / 3) % userIDs.count]
            moment.addTimeInterval(index % 3 == 0 ? 640 : 45)
            let milliseconds = UInt64(moment.timeIntervalSince1970 * 1000)
                - Snowflake<MessageTag>.epochMilliseconds
            let id = MessageID(rawValue: (milliseconds << 22) | UInt64(index + 1))
            messages.append(Message(
                id: id,
                channelID: channelID,
                authorID: author,
                content: bodies[index % bodies.count],
                kind: index % 47 == 46 ? .userJoin : .default
            ))
        }

        box.messages = messages
        box.hasMoreHistory = true
        return box
    }

    private struct RoleSpec {
        var name: String
        var color: UInt32
        var hoisted: Bool
    }

    private static let roleSpecs: [RoleSpec] = [
        RoleSpec(name: "Main Dev", color: 0xE67E22, hoisted: true),
        RoleSpec(name: "Admin", color: 0xE91E63, hoisted: true),
        RoleSpec(name: "Contributor", color: 0x2ECC71, hoisted: true),
        RoleSpec(name: "Server Booster", color: 0xF47FFF, hoisted: true),
        RoleSpec(name: "Bots", color: 0x5865F2, hoisted: true),
    ]

    private static let names = [
        "alex", "Blåhaj", "Hellomarlo", "Bram", "iamnumber7", "MarvelMallow",
        "rin", "pip", "Voltcast", "Jay", "0xC0FFEE42", "2lumin0s", "vale",
        "Void", "torriel", "vexlor", "alegre", "Toffee", "Ceruleanate", "Dyno",
        "NQN", "kazume", "Quelix", "vrm", "million", "beagle", "jamesen",
    ]

    private static let bodies = [
        "the sidebar column is painted with nothing — the system backs it",
        "that is what stops macOS re-resolving the column widths",
        "the desktop and the menu-bar accent come through for free",
        "the detail is one view type; what to show is a parameter",
        "**bold**, *italic*, `code`, and ||a spoiler|| all in one line",
        "https://example.com and a [masked link](https://example.com)",
        "one canvas, rows painted into a dirty rect, heights cached once",
        "a short one",
        "the viewport-sized backing is the whole trick — the layer never grows",
        "```swift\nlet answer = 42\n```",
        "> a quote, which parses one level in\n> and keeps its second line",
        "- a list\n- with two items",
    ]
}
