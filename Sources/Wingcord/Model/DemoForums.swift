import AppKit
import Foundation
import WingcordCore

// MARK: - Forums, invites and a private profile, for `--demo`
//
// docs/FORUMS-INVITES.md, Phase 0. None of these could be looked at without an
// account before this file: the demo had no forum at all.
//
// | fixture | where |
// | --- | --- |
// | a forum: a dozen tags, a pinned post, posts with none to five pictures, a
// |   spoiler, reactions, guidelines, slowmode, a template | The Iris Project ›
// |   #bug-reports |
// | a media channel | The Iris Project › #voxy-screenshot-contest |
// | invite links: a splash and roles, no splash, a group, a friend, a dead one,
// |   a server the reader is already in | The Iris Project › #faq |
// | a private profile | Bram, on the member list |

extension DemoFixtures {

    static func populateForumsAndInvites(_ model: AppModel, guildID: GuildID, me: UserID, people: [UserID]) {
        let others = people.filter { $0 != me }
        populateBugReports(model, guildID: guildID, me: me, people: others)
        populateMediaChannel(model, guildID: guildID, people: others)
        populateInviteLinks(model, guildID: guildID, me: me, people: others)
        populatePrivateProfile(model)
    }

    // MARK: Ids and pictures

    /// A real snowflake from a moment, so a post's age reads as it should. The
    /// serial keeps two made in the same moment apart.
    private static func snowflake(minutesAgo: Double, serial: UInt64) -> UInt64 {
        let milliseconds = UInt64(Date.now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970 * 1000)
        return ((milliseconds - Snowflake<MessageTag>.epochMilliseconds) << 22) | (serial & 0xFFF)
    }

    /// A picture drawn on this Mac, as an attachment on a post.
    private static func picture(_ scene: DemoGameArt.Scene, id: UInt64, spoiler: Bool = false) -> Attachment? {
        guard let url = DemoGameArt.picture(scene) else { return nil }
        let name = "\(spoiler ? "SPOILER_" : "")\(scene.name).png"
        return Attachment(
            id: AttachmentID(rawValue: id),
            filename: name,
            url: url.absoluteString,
            proxyURL: url.absoluteString,
            contentType: "image/png",
            size: 842_000,
            width: Int(scene.size.width),
            height: Int(scene.size.height)
        )
    }

    private static let scenes: [DemoGameArt.Scene] = [
        .init(name: "voxy-valley", symbol: "mountain.2.fill", top: (0.98, 0.62, 0.32), bottom: (0.28, 0.14, 0.42)),
        .init(name: "voxy-coast", symbol: "water.waves", top: (0.36, 0.72, 0.92), bottom: (0.06, 0.20, 0.42)),
        .init(name: "voxy-forest", symbol: "tree.fill", top: (0.48, 0.74, 0.40), bottom: (0.06, 0.22, 0.14)),
        .init(name: "voxy-night", symbol: "moon.stars.fill", top: (0.16, 0.14, 0.42), bottom: (0.02, 0.02, 0.10)),
        .init(name: "voxy-desert", symbol: "sun.max.fill", top: (0.98, 0.82, 0.50), bottom: (0.74, 0.36, 0.18)),
        .init(name: "crash-log", symbol: "exclamationmark.triangle.fill", top: (0.86, 0.26, 0.28), bottom: (0.30, 0.04, 0.10)),
        .init(name: "settings-pane", symbol: "gearshape.fill", top: (0.42, 0.46, 0.56), bottom: (0.14, 0.15, 0.20)),
    ]

    // MARK: #bug-reports

    private struct PostSpec {
        var title: String
        var tags: [Int]
        var author: Int
        var minutesAgo: Double
        var replies: Int
        var pictures: [Int] = []
        var spoilerPictures: [Int] = []
        /// A picture standing in for a video, which `--demo` can't make a poster of.
        var videos: [Int] = []
        /// A picture that arrives as a link's unfurl rather than a file.
        var embeds: [Int] = []
        var words: String
        var reactions: [Reaction] = []
        var isPinned = false
        var isLocked = false
        /// Whether the reader follows it.
        var isFollowed = false
        /// Whether it's arrived since the reader last read the forum.
        var isNew = false
        /// Replies since the reader last read it, for "(N New)".
        var unread: Int = 0
    }

    private static func populateBugReports(_ model: AppModel, guildID: GuildID, me: UserID, people: [UserID]) {
        guard let forumID = model.channelIndex.channelIDs(inGuild: guildID).first(where: {
            model.channelIndex[$0]?.name == "bug-reports"
        }), var forum = model.channelIndex[forumID] else { return }

        let tags = [
            ("New", "🆕", false), ("Needs Info", "❓", false), ("Confirmed", "✅", false),
            ("Planned", "📅", false), ("In Progress", "🔄", false), ("Fixed", "🎉", false),
            ("Won't Fix", "🚫", false), ("Duplicate", "📎", false), ("UI", "🎨", false),
            ("Voice", "🎙️", false), ("Crash", "💥", false), ("Staff Only", "🛡️", true),
        ].enumerated().map { offset, entry in
            ForumTag(
                id: ForumTagID(rawValue: 9_000_000_000_000_000_000 + UInt64(offset)),
                name: entry.0,
                isModerated: entry.2,
                emoji: EmojiRef(name: entry.1)
            )
        }
        forum.topic = """
            **Before you post**
            - Search first: most bugs have been reported already.
            - One bug per post, with the steps that reach it.
            - Attach a screenshot or a clip when you can.

            Crashes go faster with the log from `Settings › Diagnostics`. See <#\(forumID.rawValue)> for what's being worked on.
            """
        forum.availableTags = tags
        forum.defaultReaction = EmojiRef(name: "👍")
        forum.defaultAutoArchiveDuration = 10_080
        forum.rateLimitPerUser = 30
        forum.template = "**What happened**\n\n**What you expected**\n\n**Steps**\n1. "
        forum.flags.insert(.requireTag)
        forum.lastMessageID = MessageID(rawValue: snowflake(minutesAgo: 4, serial: 1))

        let specs: [PostSpec] = [
            PostSpec(
                title: "📌 Read this before reporting: how to get your bug fixed fastest",
                tags: [8], author: 0, minutesAgo: 60 * 24 * 40, replies: 0, pictures: [],
                words: "Use /bug or the button below. Say what you did, what you expected and what happened instead.",
                reactions: [Reaction(emoji: EmojiRef(name: "👍"), count: 212, isMine: true)],
                isPinned: true
            ),
            PostSpec(
                title: "Voice drops every few minutes after waking from sleep",
                tags: [0, 9], author: 1, minutesAgo: 4, replies: 18, pictures: [5],
                words: "Happens on both a 14\" and a Studio. The call stays up but nobody can hear me until I rejoin.",
                reactions: [
                    Reaction(emoji: EmojiRef(name: "👍"), count: 31, isMine: false),
                    Reaction(emoji: EmojiRef(name: "😢"), count: 4, isMine: false),
                ],
                isFollowed: true, unread: 6
            ),
            PostSpec(
                title: "Sidebar flickers when you switch servers quickly with the keyboard",
                tags: [2, 8], author: 2, minutesAgo: 22, replies: 7,
                words: "⌥↓ through a few servers and the channel list blanks for a frame each time.",
                isNew: true
            ),
            PostSpec(
                title: "Pictures in a post open at the wrong size in the viewer",
                tags: [1, 8], author: 3, minutesAgo: 75, replies: 3, pictures: [0, 1],
                words: "The second picture in a gallery opens at the first one's aspect until you zoom.",
                reactions: [Reaction(emoji: EmojiRef(name: "🔥"), count: 12, isMine: true, burstCount: 3, burstColors: [0xF4_90_0C, 0xFF_CC_4D, 0xDD_2E_44])]
            ),
            PostSpec(
                title: "Crash on launch when a custom theme has only one colour in it",
                tags: [2, 10, 4], author: 4, minutesAgo: 140, replies: 26, pictures: [5, 6, 3],
                words: "Log attached. Removing the theme from defaults gets it running again.",
                unread: 2
            ),
            PostSpec(
                title: "Screenshots from the Voxy contest don't load past the first three, and the fourth and fifth spin for ever",
                tags: [3], author: 5, minutesAgo: 300, replies: 44, pictures: [0, 1, 2, 3, 4],
                words: "All five are there if you open the post, but the board only ever draws three of them."
            ),
            PostSpec(
                title: "Marked spoiler images show through for a moment",
                tags: [1], author: 6, minutesAgo: 520, replies: 2, spoilerPictures: [3],
                words: "Right as the post opens, before the cover draws.",
                reactions: [Reaction(emoji: EmojiRef(name: "👀"), count: 5, isMine: false)]
            ),
            PostSpec(
                title: "Screen recording of the scroll jump in a long thread",
                tags: [2, 8], author: 3, minutesAgo: 610, replies: 5, videos: [6],
                words: "It happens right at the end of the clip, about four seconds in."
            ),
            PostSpec(
                title: "Link previews from the wiki have the wrong picture",
                tags: [1, 8], author: 5, minutesAgo: 690, replies: 1, embeds: [2],
                words: "See https://example.com/wiki/voxy for one that does it every time.",
                reactions: [Reaction(emoji: EmojiRef(name: "🤔"), count: 2, isMine: false)]
            ),
            PostSpec(
                title: "Can't drag a file onto a thread beside its channel",
                tags: [0, 8], author: 2, minutesAgo: 760, replies: 1,
                words: "Dropping on the transcript in the side panel does nothing at all.",
                isNew: true
            ),
            PostSpec(
                title: "Mic test meter never moves on a USB interface",
                tags: [5, 9], author: 7, minutesAgo: 1_300, replies: 11, pictures: [6],
                words: "Fixed in the last build for me, leaving this here for anyone searching."
            ),
            PostSpec(
                title: "Locked: duplicate of the voice drop thread",
                tags: [7], author: 1, minutesAgo: 2_100, replies: 0,
                words: "Please follow the other post.",
                isLocked: true
            ),
            PostSpec(
                title: "Staff notes on the next release",
                tags: [11, 3], author: 0, minutesAgo: 3_000, replies: 9,
                words: "What's going in, what's being held back."
            ),
        ]

        // The tags, in the channel, before the posts resolve against it.
        model.channelIndex.upsert(forum)
        // The sidebar shows what's followed, and the fixture leaves the server's
        // last two channels out of that on purpose.
        model.followedChannelIDs.insert(forumID)

        var board = ForumBoard(query: ForumQuery(defaultsOf: forum))
        var serial: UInt64 = 10
        let readMark = MessageID(rawValue: snowflake(minutesAgo: 900, serial: 0))
        for spec in specs {
            serial += 1
            let postID = ChannelID(rawValue: snowflake(minutesAgo: spec.minutesAgo + 30, serial: serial))
            let author = people[spec.author % people.count]
            var flags: ChannelFlags = []
            if spec.isPinned { flags.insert(.pinned) }
            // The post's newest message is the one its transcript ends on: a post
            // whose pointer is past what it holds looks cut off from the present,
            // and asks a server for the rest.
            let lastMessage = spec.replies > 0
                ? MessageID(rawValue: snowflake(minutesAgo: spec.minutesAgo, serial: serial))
                : MessageID(rawValue: postID.rawValue)
            model.channelIndex.upsertThread(Channel(
                id: postID,
                kind: .publicThread,
                guildID: guildID,
                name: spec.title,
                parentID: forumID,
                lastMessageID: lastMessage,
                ownerID: author,
                messageCount: spec.replies,
                threadMetadata: ThreadMetadata(isLocked: spec.isLocked, createdAt: postID.timestamp),
                appliedTags: spec.tags.map { tags[$0].id },
                flags: flags,
                memberCount: spec.replies + 1,
                memberIDsPreview: Array(people.prefix(min(5, spec.replies + 1)))
            ))
            var attachments: [Attachment] = []
            for (offset, index) in spec.pictures.enumerated() {
                if let file = picture(scenes[index], id: postID.rawValue + 100 + UInt64(offset)) { attachments.append(file) }
            }
            for (offset, index) in spec.spoilerPictures.enumerated() {
                if let file = picture(scenes[index], id: postID.rawValue + 200 + UInt64(offset), spoiler: true) { attachments.append(file) }
            }
            for (offset, index) in spec.videos.enumerated() {
                guard var file = picture(scenes[index], id: postID.rawValue + 300 + UInt64(offset)) else { continue }
                file.contentType = "video/mp4"
                attachments.append(file)
            }
            let embeds: [Embed] = spec.embeds.compactMap { index in
                guard let url = DemoGameArt.picture(scenes[index]) else { return nil }
                return Embed(
                    title: "Voxy wiki",
                    kind: "article",
                    url: "https://example.com/wiki/voxy",
                    image: Embed.Media(url: url.absoluteString, proxyURL: url.absoluteString, width: 1200, height: 800)
                )
            }
            let opener = Message(
                id: MessageID(rawValue: postID.rawValue),
                channelID: postID,
                authorID: author,
                content: spec.words,
                payload: attachments.isEmpty && spec.reactions.isEmpty && embeds.isEmpty
                    ? nil : MessagePayload(attachments: attachments, embeds: embeds, reactions: spec.reactions)
            )
            board.firstMessages[postID] = opener
            board.detailsRequested.insert(postID)
            board.detailsAnswered.insert(postID)

            // A transcript to open onto: the opening message and a few replies.
            var box = MessageBox()
            let shownReplies = min(spec.replies, 4)
            box.messages = [opener] + (0..<shownReplies).map { offset in
                Message(
                    id: offset == shownReplies - 1
                        ? lastMessage
                        : MessageID(rawValue: snowflake(minutesAgo: spec.minutesAgo + Double(4 - offset), serial: serial + 100 + UInt64(offset))),
                    channelID: postID,
                    authorID: people[(spec.author + offset + 1) % people.count],
                    content: ["Same here.", "Which build is this on?", "Can you attach the log?", "Thanks, looking into it."][offset]
                )
            }
            box.hasMoreHistory = false
            model.demoTranscripts[postID] = box

            if spec.isFollowed {
                model.threadMemberships[postID] = ThreadMember(id: postID, userID: me, joinedAt: .now)
            }
            // Opened before, up to a point: unread where the post asks for it,
            // read otherwise. A post with no read state at all is "NEW".
            if !spec.isNew {
                model.readStates[postID] = ReadState(
                    lastAcknowledgedID: spec.unread > 0
                        ? MessageID(rawValue: snowflake(minutesAgo: spec.minutesAgo + 1, serial: serial))
                        : lastMessage,
                    mentionCount: 0,
                    isMuted: false
                )
            }
            model.forumPostUnreadCounts[postID] = spec.unread > 0 ? spec.unread : nil
        }

        // Older Posts: a page the server would answer with.
        let archived: [(String, [Int], Int, [Int])] = [
            ("Emoji picker opens behind the composer on a small window", [5, 8], 3, [6]),
            ("Reactions jump a pixel when somebody else adds one", [5, 8], 2, []),
            ("Notifications arrive twice for a mention in a thread", [6], 5, []),
            ("Stream preview is black until the first keyframe", [5, 9], 4, [3]),
        ]
        for (offset, entry) in archived.enumerated() {
            serial += 1
            let minutes = 60.0 * 24 * Double(9 + offset * 3)
            let postID = ChannelID(rawValue: snowflake(minutesAgo: minutes, serial: serial))
            let author = people[entry.2 % people.count]
            model.channelIndex.upsertThread(Channel(
                id: postID,
                kind: .publicThread,
                guildID: guildID,
                name: entry.0,
                parentID: forumID,
                lastMessageID: MessageID(rawValue: snowflake(minutesAgo: minutes - 30, serial: serial)),
                ownerID: author,
                messageCount: 3 + offset,
                threadMetadata: ThreadMetadata(isArchived: true, createdAt: postID.timestamp),
                appliedTags: entry.1.map { tags[$0].id }
            ))
            let attachments = entry.3.compactMap { picture(scenes[$0], id: postID.rawValue + 100) }
            let opener = Message(
                id: MessageID(rawValue: postID.rawValue),
                channelID: postID,
                authorID: author,
                content: "This one's been fixed for a while, kept for anyone searching.",
                payload: attachments.isEmpty ? nil : MessagePayload(attachments: attachments)
            )
            board.firstMessages[postID] = opener
            board.detailsRequested.insert(postID)
            board.detailsAnswered.insert(postID)
            board.postIDs.append(postID)
            board.seen.insert(postID)
            model.readStates[postID] = ReadState(lastAcknowledgedID: MessageID(rawValue: postID.rawValue), mentionCount: 0, isMuted: false)
            var box = MessageBox()
            box.messages = [opener]
            box.hasMoreHistory = false
            model.demoTranscripts[postID] = box
        }
        board.servedCount = board.postIDs.count
        board.totalResults = board.postIDs.count
        model.forumBoards[forumID] = board
        model.forumReadMarks[forumID] = readMark
        model.readStates[forumID] = ReadState(lastAcknowledgedID: readMark, mentionCount: 0, isMuted: false)
        model.threadRevision &+= 1
        model.sidebarRevision &+= 1
    }

    // MARK: Somebody else posting

    private static var arrivalsScheduled: Set<ChannelID> = []

    /// Two posts from somebody else, a few seconds after #bug-reports is first opened,
    /// so "N New Posts" can be looked at: they come through the gateway's own path.
    static func scheduleForumArrivals(in forumID: ChannelID, model: AppModel) {
        guard model.channelIndex[forumID]?.name == "bug-reports", arrivalsScheduled.insert(forumID).inserted else { return }
        let people = (model.forumBoards[forumID]?.firstMessages.values.map(\.authorID) ?? []).filter { $0 != model.currentUserID }
        guard let author = people.first else { return }
        let titles = [
            "Threads opened from a notification land on the wrong message",
            "Custom status emoji disappears after a restart",
        ]
        Task { @MainActor [weak model] in
            for (offset, title) in titles.enumerated() {
                try? await Task.sleep(for: .seconds(offset == 0 ? 7 : 4))
                guard let model else { return }
                let postID = ChannelID(rawValue: snowflake(minutesAgo: 0, serial: 950 + UInt64(offset)))
                let opener = Message(
                    id: MessageID(rawValue: postID.rawValue),
                    channelID: postID,
                    authorID: author,
                    content: "Just started happening on the latest build."
                )
                model.forumBoards[forumID]?.firstMessages[postID] = opener
                model.forumBoards[forumID]?.detailsAnswered.insert(postID)
                var box = MessageBox()
                box.messages = [opener]
                box.hasMoreHistory = false
                model.demoTranscripts[postID] = box
                model.applyThreadUpsert(
                    Channel(
                        id: postID,
                        kind: .publicThread,
                        guildID: model.channelIndex[forumID]?.guildID,
                        name: title,
                        parentID: forumID,
                        lastMessageID: MessageID(rawValue: postID.rawValue),
                        ownerID: author,
                        messageCount: 0,
                        threadMetadata: ThreadMetadata(createdAt: postID.timestamp),
                        appliedTags: []
                    ),
                    membership: nil,
                    isNewlyCreated: true
                )
            }
        }
    }

    // MARK: #voxy-screenshot-contest

    private static func populateMediaChannel(_ model: AppModel, guildID: GuildID, people: [UserID]) {
        guard let channelID = model.channelIndex.channelIDs(inGuild: guildID).first(where: {
            model.channelIndex[$0]?.name == "voxy-screenshot-contest"
        }), var channel = model.channelIndex[channelID] else { return }
        let tags = [("Landscape", "🏔️"), ("Build", "🧱"), ("Night", "🌙"), ("Winner", "🏆")].enumerated().map { offset, entry in
            ForumTag(id: ForumTagID(rawValue: 9_100_000_000_000_000_000 + UInt64(offset)), name: entry.0, emoji: EmojiRef(name: entry.1))
        }
        channel.topic = "Post one screenshot per entry. Voting closes on Sunday."
        channel.availableTags = tags
        channel.defaultReaction = EmojiRef(name: "🔥")
        channel.lastMessageID = MessageID(rawValue: snowflake(minutesAgo: 8, serial: 2))
        model.channelIndex.upsert(channel)

        var board = ForumBoard(query: ForumQuery(defaultsOf: channel))
        let entries: [(String, Int, Int)] = [
            ("Sunset over the valley", 0, 0), ("First light at the coast", 1, 0), ("Deep in the old forest", 2, 0),
            ("Midnight on the ridge", 3, 2), ("Heat haze", 4, 0), ("The long road home", 0, 1),
        ]
        for (offset, entry) in entries.enumerated() {
            let serial = 500 + UInt64(offset)
            let minutes = 8 + Double(offset) * 90
            let postID = ChannelID(rawValue: snowflake(minutesAgo: minutes, serial: serial))
            let author = people[(offset + 3) % people.count]
            model.channelIndex.upsertThread(Channel(
                id: postID,
                kind: .publicThread,
                guildID: guildID,
                name: entry.0,
                parentID: channelID,
                lastMessageID: MessageID(rawValue: postID.rawValue),
                ownerID: author,
                messageCount: offset * 3,
                threadMetadata: ThreadMetadata(createdAt: postID.timestamp),
                appliedTags: [tags[entry.2].id]
            ))
            let attachments = [picture(scenes[entry.1], id: postID.rawValue + 100)].compactMap { $0 }
            let opener = Message(
                id: MessageID(rawValue: postID.rawValue),
                channelID: postID,
                authorID: author,
                content: "",
                payload: MessagePayload(attachments: attachments, reactions: [
                    Reaction(emoji: EmojiRef(name: "🔥"), count: 12 - offset, isMine: offset == 1),
                ])
            )
            board.firstMessages[postID] = opener
            board.detailsRequested.insert(postID)
            board.detailsAnswered.insert(postID)
            var box = MessageBox()
            box.messages = [opener]
            box.hasMoreHistory = false
            model.demoTranscripts[postID] = box
            model.readStates[postID] = ReadState(lastAcknowledgedID: MessageID(rawValue: postID.rawValue), mentionCount: 0, isMuted: false)
        }
        model.forumBoards[channelID] = board
    }

    // MARK: Invite links

    /// One link of each kind, in #faq, so a click on the words reaches the sheet in
    /// every state it has. Not in the channel the demo opens on, whose foot other
    /// fixtures have spoken for (`DemoFixtureTests`).
    private static func populateInviteLinks(_ model: AppModel, guildID: GuildID, me: UserID, people: [UserID]) {
        guard let opensOn = model.selectedChannelID, let inviter = people.first,
              let channelID = model.channelIndex.channelIDs(inGuild: guildID).first(where: {
                  model.channelIndex[$0]?.name == "faq"
              })
        else { return }
        let author = model.users[inviter]

        let craft = GuildID(rawValue: 1_400_000_000_000_000_778)
        model.inviteLookups["demo-craft"] = .resolved(InviteCard(
            code: "demo-craft", kind: .server, guildID: craft, name: "Then We Craft ⛏",
            features: ["COMMUNITY"], boostTier: 2, boostCount: 9, memberCount: 18_402, onlineCount: 2_847,
            inviterID: inviter, inviterName: author?.displayName, inviterUsername: author?.username,
            expiresAt: .now.addingTimeInterval(3 * 86_400 + 600),
            isNicknameChangeable: true,
            grantedRoles: [
                InviteGrantedRole(id: RoleID(rawValue: 7_100), name: "Crafter", colorValue: 0x57_F2_87),
                InviteGrantedRole(id: RoleID(rawValue: 7_101), name: "Newcomer", colorValue: 0xFE_E7_5C),
            ]
        ))
        model.demoInviteArt["demo-craft"] = DemoInviteArt(
            icon: DemoGameArt.tile(symbol: "hammer.fill", top: (0.42, 0.72, 0.40), bottom: (0.12, 0.30, 0.20), name: "invite-craft"),
            splash: DemoGameArt.picture(.init(
                name: "invite-craft-splash", symbol: "sun.horizon.fill",
                top: (0.98, 0.62, 0.28), bottom: (0.12, 0.26, 0.40), size: CGSize(width: 1040, height: 800)
            ))
        )

        let plain = GuildID(rawValue: 1_400_000_000_000_000_779)
        model.inviteLookups["demo-plain"] = .resolved(InviteCard(
            code: "demo-plain", kind: .server, guildID: plain, name: "Quiet Corner",
            memberCount: 86, onlineCount: 12,
            inviterID: inviter, inviterName: author?.displayName, inviterUsername: author?.username
        ))

        model.inviteLookups["demo-group"] = .resolved(InviteCard(
            code: "demo-group", kind: .groupDirectMessage, channelID: ChannelID(rawValue: 1_400_000_000_000_000_780),
            name: "weekend plans", memberCount: 4,
            inviterID: inviter, inviterName: author?.displayName, inviterUsername: author?.username
        ))
        // Somebody the reader isn't friends with: a friend's link just opens the
        // conversation.
        let stranger = people.last { model.relationship(with: $0) == .none } ?? inviter
        model.inviteLookups["demo-friend"] = .resolved(InviteCard(
            code: "demo-friend", kind: .friend, name: model.users[stranger]?.displayName ?? "A friend",
            inviterID: stranger,
            inviterName: model.users[stranger]?.displayName,
            inviterUsername: model.users[stranger]?.username
        ))
        model.inviteLookups["demo-dead"] = .invalid

        // The one the reader is already in: goes there, no sheet. To the channel the
        // demo opens on, so going there can be seen.
        let own = model.selectedGuildID
        model.inviteLookups["demo-iris"] = .resolved(InviteCard(
            code: "demo-iris", kind: .server, guildID: own, channelID: opensOn,
            name: own.flatMap { model.guilds[$0]?.name } ?? "This server",
            inviterID: inviter, inviterName: author?.displayName, inviterUsername: author?.username
        ))

        let lines = [
            ("come craft with us https://discord.gg/demo-craft", inviter),
            ("small server, no art: https://discord.gg/demo-plain", inviter),
            ("the group for this weekend https://discord.gg/demo-group", inviter),
            ("add me https://discord.gg/demo-friend", inviter),
            ("this one's dead https://discord.gg/demo-dead", inviter),
            ("you're already here https://discord.gg/demo-iris", inviter),
        ]
        var box = MessageBox()
        box.hasMoreHistory = false
        for (offset, entry) in lines.enumerated() {
            box.messages.append(Message(
                id: MessageID(rawValue: snowflake(minutesAgo: Double(lines.count - offset) * 3, serial: 800 + UInt64(offset))),
                channelID: channelID,
                authorID: entry.1,
                content: entry.0
            ))
        }
        model.demoTranscripts[channelID] = box
    }

    /// The slide landed, with no server to ask. `demo-plain` is refused, so the
    /// knob's way home can be looked at; anything else joins a fabricated server.
    @MainActor
    static func acceptInvite(_ card: InviteCard, model: AppModel) async {
        try? await Task.sleep(for: .milliseconds(900))
        guard model.inviteSheet?.card?.code == card.code else { return }
        if card.code == "demo-plain" {
            model.inviteSheet?.failure = "You can't join that server."
            return
        }
        model.inviteSheet = nil
        guard card.kind == .server, let guildID = card.guildID, let me = model.currentUserID else { return }
        model.guilds[guildID] = Guild(
            id: guildID, name: card.name, ownerID: me,
            features: Set(card.features), memberCount: card.memberCount
        )
        let category = ChannelID(rawValue: guildID.rawValue &+ 1)
        let general = ChannelID(rawValue: guildID.rawValue &+ 2)
        model.channelIndex.replaceChannels([
            Channel(id: category, kind: .category, guildID: guildID, name: "Text Channels"),
            Channel(id: general, kind: .text, guildID: guildID, name: "general", parentID: category, position: 1),
        ], inGuild: guildID)
        let everyone = RoleID(rawValue: guildID.rawValue)
        model.roles[guildID] = [
            everyone: Role(id: everyone, name: "@everyone", position: 0, permissions: [
                .viewChannel, .readMessageHistory, .sendMessages, .addReactions, .attachFiles, .embedLinks,
            ]),
        ]
        model.folders.append(GuildFolder(guildIDs: [guildID]))
        var empty = MessageBox()
        empty.hasMoreHistory = false
        model.setMessages(empty, in: general)
        model.roleRevision &+= 1
        model.railRevision &+= 1
        model.sidebarRevision &+= 1
        model.selectGuild(guildID)
        model.selectChannel(general)
    }

    // MARK: A post, sent

    enum ForumPostError: Error {
        case blockedTitle
    }

    /// A post, with no server to ask. A title with "blocked" in it is refused as
    /// AutoMod would, so the card's way of saying so can be looked at.
    @MainActor
    static func createForumPost(
        _ draft: ForumPostDraft,
        content: String,
        files: [PendingAttachment],
        in forum: Channel,
        model: AppModel
    ) async throws -> Channel {
        // The files' turn, slowly enough to watch.
        if !files.isEmpty {
            for step in 1...8 {
                try? await Task.sleep(for: .milliseconds(120))
                model.forumPostUploadProgress[forum.id] = Double(step) / 8
            }
        } else {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if draft.title.localizedCaseInsensitiveContains("blocked") { throw ForumPostError.blockedTitle }
        let postID = ChannelID(rawValue: snowflake(minutesAgo: 0, serial: 900))
        let post = Channel(
            id: postID,
            kind: .publicThread,
            guildID: forum.guildID,
            name: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            parentID: forum.id,
            lastMessageID: MessageID(rawValue: postID.rawValue),
            ownerID: model.currentUserID,
            messageCount: 0,
            threadMetadata: ThreadMetadata(
                autoArchiveMinutes: forum.defaultAutoArchiveDuration ?? 4320,
                createdAt: postID.timestamp
            ),
            appliedTags: Array(draft.tags)
        )
        let attachments = files.enumerated().map { offset, file in
            Attachment(
                id: AttachmentID(rawValue: postID.rawValue + 10 + UInt64(offset)),
                filename: (file.isSpoiler ? "SPOILER_" : "") + file.filename,
                url: file.url.absoluteString,
                proxyURL: file.url.absoluteString,
                contentType: file.contentType?.preferredMIMEType,
                size: file.size,
                width: 1200,
                height: 800
            )
        }
        let opener = Message(
            id: MessageID(rawValue: postID.rawValue),
            channelID: postID,
            authorID: model.currentUserID ?? UserID(rawValue: 0),
            content: content,
            payload: attachments.isEmpty ? nil : MessagePayload(attachments: attachments)
        )
        model.channelIndex.upsertThread(post)
        model.forumBoards[forum.id]?.firstMessages[postID] = opener
        model.forumBoards[forum.id]?.detailsAnswered.insert(postID)
        var box = MessageBox()
        box.messages = [opener]
        box.hasMoreHistory = false
        model.demoTranscripts[postID] = box
        return post
    }

    /// The files, on a post's opening message, with no server to ask.
    @MainActor
    static func addMediaToPost(_ files: [PendingAttachment], postID: ChannelID, model: AppModel) async throws -> Message {
        try? await Task.sleep(for: .milliseconds(800))
        let openerID = MessageID(rawValue: postID.rawValue)
        guard let opener = model.message(openerID, in: postID) else { throw ForumPostError.blockedTitle }
        var updated = opener
        let added = files.enumerated().map { offset, file in
            Attachment(
                id: AttachmentID(rawValue: postID.rawValue + 40 + UInt64(offset)),
                filename: (file.isSpoiler ? "SPOILER_" : "") + file.filename,
                url: file.url.absoluteString,
                proxyURL: file.url.absoluteString,
                contentType: file.contentType?.preferredMIMEType,
                size: file.size,
                width: 1200,
                height: 800
            )
        }
        updated.payload = (opener.payload ?? MessagePayload()).replacingAttachments(opener.attachments + added)
        return updated
    }

    // MARK: A private profile

    private static func populatePrivateProfile(_ model: AppModel) {
        guard let person = model.users.values.first(where: { $0.displayName == "Bram" }) else { return }
        let lock = User(id: person.id, username: person.username, decoration: UserDecoration(isProfilePrivate: true))
        model.users[person.id] = lock.merged(over: person)
    }
}

extension AppModel {
    /// A transcript `--demo` holds back until something opens it.
    ///
    /// **Not seeded into the store, because the store keeps three.** A board's worth of
    /// `setMessages` evicted the conversation the overlay opens on, and all but the last
    /// three posts, so clicking a post asked a server that isn't there. A fixture that
    /// exceeds the store's own bound deletes itself (`DemoFixtures`' note on the
    /// conversations says the same). A post's opening message comes from its board, which
    /// is what's been reacted to since.
    func demoTranscript(for channelID: ChannelID) -> MessageBox? {
        guard var box = demoTranscripts[channelID] else { return nil }
        if let forumID = channelIndex[channelID]?.parentID,
           let opener = forumBoards[forumID]?.firstMessages[channelID],
           let index = box.messages.firstIndex(where: { $0.id == opener.id })
        {
            box.messages[index] = opener
        }
        return box
    }
}

/// Art an invite would have on the CDN, for `--demo`, which has nothing there.
struct DemoInviteArt {
    var icon: URL?
    var splash: URL?
}
