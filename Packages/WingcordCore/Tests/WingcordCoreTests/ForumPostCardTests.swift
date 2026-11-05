import Foundation
import Testing
@testable import WingcordCore

/// What a post's row says about its opening message: Discord's `256265`, `lQ`, `k6`
/// and `th`.
@Suite("Forum post cards")
struct ForumPostCardTests {

    private func file(
        _ id: UInt64,
        name: String = "a.png",
        proxy: String = "https://media.discordapp.net/attachments/1/2/a.png",
        type: String? = "image/png",
        width: Int? = 800,
        height: Int? = 600,
        isThumbnail: Bool = false
    ) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: id),
            filename: name,
            url: proxy,
            proxyURL: proxy,
            contentType: type,
            width: width,
            height: height,
            isThumbnail: isThumbnail
        )
    }

    private func opener(
        content: String = "words",
        attachments: [WingcordCore.Attachment] = [],
        embeds: [Embed] = []
    ) -> Message {
        Message(
            id: MessageID(rawValue: 5),
            channelID: ChannelID(rawValue: 5),
            authorID: UserID(rawValue: 1),
            content: content,
            payload: MessagePayload(attachments: attachments, embeds: embeds)
        )
    }

    private func embed(_ url: String) -> Embed {
        Embed(image: Embed.Media(url: url, proxyURL: url, width: 400, height: 300))
    }

    // MARK: Pictures

    @Test("Files lead, then what the embeds lead with, and neither is the full-size original")
    func order() throws {
        let media = ForumPostCard.media(
            of: opener(attachments: [file(1)], embeds: [embed("https://images-ext-1.discordapp.net/external/x.png")]),
            isMediaChannel: false,
            width: 450
        )
        #expect(media.count == 2)
        #expect(media[0].url.path.hasSuffix("a.png"))
        #expect(media[1].url.path.hasSuffix("x.png"))
        #expect(media[0].url.query?.contains("width=900") == true, "twice the points, for the display")
    }

    @Test("Without an image of its own, an embed's thumbnail stands in")
    func embedThumbnail() {
        var card = Embed()
        card.thumbnail = Embed.Media(url: "https://a.example/t.png", width: 80, height: 80)
        let media = ForumPostCard.media(of: opener(embeds: [card]), isMediaChannel: false, width: 72)
        #expect(media.count == 1)
        #expect(media[0].url.path.hasSuffix("t.png"))
    }

    @Test("A file that isn't a picture, or a picture of no known size, has no place on a board")
    func notPictures() {
        let media = ForumPostCard.media(
            of: opener(attachments: [
                file(1, name: "log.txt", type: "text/plain", width: nil, height: nil),
                file(2, width: nil, height: nil),
                file(3, width: 0, height: 0),
            ]),
            isMediaChannel: false,
            width: 72
        )
        #expect(media.isEmpty)
    }

    @Test("A video is its poster, marked, because its own URL isn't a picture")
    func video() throws {
        let media = ForumPostCard.media(
            of: opener(attachments: [
                file(1, name: "clip.mp4", proxy: "https://media.discordapp.net/attachments/1/2/clip.mp4", type: "video/mp4"),
            ]),
            isMediaChannel: false,
            width: 72
        )
        let poster = try #require(media.first)
        #expect(poster.isVideo)
        #expect(poster.url.query?.contains("format=webp") == true)
    }

    @Test("A video with no poster to ask for is left out, unless it's a picture on this Mac")
    func posterlessVideo() {
        let elsewhere = file(1, name: "clip.mp4", proxy: "ftp://a.example/clip.mp4", type: "video/mp4")
        #expect(ForumPostCard.media(of: opener(attachments: [elsewhere]), isMediaChannel: false, width: 72).isEmpty)

        let onThisMac = file(2, name: "clip.png", proxy: "file:///tmp/clip.png", type: "video/mp4")
        let media = ForumPostCard.media(of: opener(attachments: [onThisMac]), isMediaChannel: false, width: 72)
        #expect(media.first?.isVideo == true)
        #expect(media.first?.url.absoluteString == "file:///tmp/clip.png")
    }

    @Test("A GIF says so, a spoiler is covered, and a spoilered link covers what it unfurls to")
    func marks() {
        let gif = file(1, name: "a.gif", proxy: "https://media.discordapp.net/attachments/1/2/a.gif", type: "image/gif")
        let spoiler = file(2, name: "SPOILER_a.png")
        let media = ForumPostCard.media(of: opener(attachments: [gif, spoiler]), isMediaChannel: false, width: 72)
        #expect(media[0].isAnimated)
        #expect(!media[0].isSpoiler)
        #expect(media[1].isSpoiler)

        let covered = ForumPostCard.media(
            of: opener(content: "see ||https://a.example/x||", embeds: [embed("https://a.example/x.png")]),
            isMediaChannel: false,
            width: 72
        )
        #expect(covered.first?.isSpoiler == true)
    }

    @Test("On a media channel the chosen thumbnail stands for the post")
    func mediaThumbnail() {
        let message = opener(attachments: [file(1, name: "first.png"), file(2, name: "chosen.png", isThumbnail: true)])
        #expect(ForumPostCard.media(of: message, isMediaChannel: false, width: 450).count == 2)
        #expect(ForumPostCard.media(of: message, isMediaChannel: true, width: 450).count == 1)
        // With none chosen, it's all of them.
        let plain = opener(attachments: [file(1), file(2)])
        #expect(ForumPostCard.media(of: plain, isMediaChannel: true, width: 450).count == 2)
    }

    @Test("With embeds turned off, only the files")
    func embedsOff() {
        let message = opener(attachments: [file(1)], embeds: [embed("https://a.example/x.png")])
        #expect(ForumPostCard.media(of: message, isMediaChannel: false, width: 72, showsEmbeds: false).count == 1)
    }

    @Test("A link is under a spoiler only between a pair of marks")
    func spoilerLinks() {
        #expect(ForumPostCard.hasSpoilerLink("see ||https://a.example/x|| now"))
        #expect(ForumPostCard.hasSpoilerLink("||http://a.example||"))
        #expect(!ForumPostCard.hasSpoilerLink("https://a.example/x"))
        #expect(!ForumPostCard.hasSpoilerLink("||just words||"))
        #expect(!ForumPostCard.hasSpoilerLink("||one|| https://a.example ||two||"), "between two spoilers, in the open")
        #expect(!ForumPostCard.hasSpoilerLink("|| https://a.example never closed"))
        #expect(ForumPostCard.hasSpoilerLink("||one|| words ||https://a.example||"))
    }

    // MARK: Reactions

    @Test("The most reactions of either kind, then the most super ones, then whichever came first")
    func topReaction() {
        func reaction(_ name: String, _ count: Int, burst: Int = 0) -> Reaction {
            Reaction(emoji: EmojiRef(name: name), count: count, isMine: false, burstCount: burst)
        }
        #expect(ForumPostCard.topReaction(of: []) == nil)
        #expect(ForumPostCard.topReaction(of: [reaction("a", 3), reaction("b", 2, burst: 2)])?.emoji.name == "b")
        #expect(ForumPostCard.topReaction(of: [reaction("a", 2), reaction("b", 1, burst: 1)])?.emoji.name == "b")
        #expect(ForumPostCard.topReaction(of: [reaction("a", 2), reaction("b", 2)])?.emoji.name == "a")
    }

    // MARK: How many are new

    @Test("Discord's count: \"1+\" when nobody has said, never above the post's own, capped")
    func unreadWords() {
        #expect(ForumPostCard.unreadWords(count: nil, total: 10) == "1+")
        #expect(ForumPostCard.unreadWords(count: 0, total: 10) == "1+")
        #expect(ForumPostCard.unreadWords(count: 3, total: 10) == "3")
        #expect(ForumPostCard.unreadWords(count: 30, total: 12) == "12")
        #expect(ForumPostCard.unreadWords(count: 25, total: 100) == "25+")
        #expect(ForumPostCard.unreadWords(count: 3, total: 0) == "3", "a post that hasn't said how many it has")
    }

    // MARK: A search's words

    @Test("Each word on its own, whatever the case, in the order they fall")
    func matches() {
        let title = "Voice drops after waking from SLEEP, voice again"
        let found = ForumPostCard.matches(of: "sleep voice", in: title).map { String(title[$0]) }
        #expect(found == ["Voice", "SLEEP", "voice"])
        #expect(ForumPostCard.matches(of: "nothing", in: title).isEmpty)
        #expect(ForumPostCard.matches(of: "   ", in: title).isEmpty)
    }
}

/// A board doesn't reorder itself under somebody reading it (`207777`).
@Suite("Forum board hold")
struct ForumHeldOrderTests {

    private func id(_ seconds: Double) -> UInt64 { UInt64(seconds * 1000) << 22 }

    private func post(
        _ created: Double,
        lastMessage: Double? = nil,
        pinned: Bool = false,
        tags: [UInt64] = []
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: id(created)),
            kind: .publicThread,
            lastMessageID: lastMessage.map { MessageID(rawValue: id($0)) },
            appliedTags: tags.map { ForumTagID(rawValue: $0) },
            flags: pinned ? .pinned : []
        )
    }

    private func held(_ posts: [Channel], query: ForumQuery = ForumQuery()) -> [ChannelID] {
        ForumOrder.livePosts(posts, query: query)
    }

    @Test("A post answered since stays where the reader last saw it")
    func answeredStays() {
        let a = post(1, lastMessage: 1)
        let b = post(2, lastMessage: 2)
        let order = held([a, b])
        #expect(order == [b.id, a.id])

        let answered = post(1, lastMessage: 9)
        #expect(ForumOrder.livePosts([answered, b], query: ForumQuery()) == [a.id, b.id], "what a refresh would say")
        #expect(ForumOrder.heldPosts([answered, b], query: ForumQuery(), held: order, waiting: []) == [b.id, a.id])
    }

    @Test("Somebody else's new post waits until the reader asks")
    func newPostWaits() {
        let a = post(1, lastMessage: 1)
        let fresh = post(5, lastMessage: 5)
        let order = held([a])
        #expect(ForumOrder.heldPosts([a, fresh], query: ForumQuery(), held: order, waiting: [fresh.id]) == [a.id])
        #expect(ForumOrder.heldPosts([a, fresh], query: ForumQuery(), held: order, waiting: []) == [fresh.id, a.id])
    }

    @Test("A post gone since drops out")
    func goneDrops() {
        let a = post(1)
        let b = post(2)
        #expect(ForumOrder.heldPosts([a], query: ForumQuery(), held: [b.id, a.id], waiting: []) == [a.id])
    }

    @Test("A post pinned since is at the top straight away")
    func pinnedLeads() {
        let a = post(1)
        let b = post(2)
        let pinned = post(1, pinned: true)
        #expect(ForumOrder.heldPosts([pinned, b], query: ForumQuery(), held: [b.id, a.id], waiting: []) == [a.id, b.id])
    }

    @Test("A post the filter hides isn't shown for being held")
    func filterApplies() {
        let a = post(1, tags: [7])
        let b = post(2)
        var query = ForumQuery()
        query.tags = [ForumTagID(rawValue: 7)]
        #expect(ForumOrder.heldPosts([a, b], query: query, held: [b.id, a.id], waiting: []) == [a.id])
    }

    @Test("Nothing held yet is the fresh order, less what's waiting")
    func nothingHeld() {
        let a = post(1, lastMessage: 1)
        let b = post(2, lastMessage: 2)
        #expect(ForumOrder.heldPosts([a, b], query: ForumQuery(), held: [], waiting: [b.id]) == [a.id])
    }
}

/// What a board opens at, and what Reset goes back to.
@Suite("Forum query defaults")
struct ForumQueryDefaultsTests {

    private func channel(_ kind: ChannelKind) -> Channel {
        var channel = Channel(id: ChannelID(rawValue: 1), kind: kind, name: "board")
        channel.defaultSortOrder = .creationDate
        channel.defaultForumLayout = .list
        channel.defaultTagMatching = .all
        return channel
    }

    @Test("A forum opens as it was set up")
    func forum() {
        let query = ForumQuery(defaultsOf: channel(.forum))
        #expect(query.sortOrder == .creationDate)
        #expect(query.layout == .list)
        #expect(query.tagMatching == .all)
    }

    @Test("A media channel is always a gallery, whatever it says")
    func media() {
        #expect(ForumQuery(defaultsOf: channel(.media)).layout == .gallery)
    }

    @Test("Reset goes back to the forum's own, and the lit tags stay lit")
    func reset() {
        let defaults = ForumQuery(defaultsOf: channel(.forum))
        var changed = defaults
        changed.sortOrder = .recentActivity
        changed.layout = .gallery
        changed.tagMatching = .some
        changed.tags = [ForumTagID(rawValue: 9)]
        let reset = changed.resettingToDefaults(defaults)
        #expect(reset.sortOrder == .creationDate)
        #expect(reset.layout == .list)
        #expect(reset.tagMatching == .all)
        #expect(reset.tags == [ForumTagID(rawValue: 9)])
    }
}

/// A clicked link, and what the sheet says about an invite's time.
@Suite("Invite links")
struct InviteLinkTests {

    @Test("A link that is nothing but an invite is its key")
    func invites() {
        #expect(InviteCard.key(ofLink: "https://discord.gg/wingcord") == "wingcord")
        #expect(InviteCard.key(ofLink: "discord.gg/wingcord/") == "wingcord")
        #expect(InviteCard.key(ofLink: "https://discord.com/invite/wingcord") == "wingcord")
        #expect(InviteCard.key(ofLink: "https://discordapp.com/invite/wingcord") == "wingcord")
        #expect(InviteCard.key(ofLink: "https://ptb.discord.com/invite/wingcord") == "wingcord")
        #expect(InviteCard.key(ofLink: "https://discord.gg/wingcord#fragment") == "wingcord")
        #expect(InviteCard.key(ofLink: "https://discord.gg/wingcord?event=42") == "wingcord?event=42")
    }

    @Test("Anything else goes to the browser")
    func notInvites() {
        #expect(InviteCard.key(ofLink: "https://example.com/discord.gg/wingcord") == nil)
        #expect(InviteCard.key(ofLink: "https://discord.com/channels/1/2") == nil)
        #expect(InviteCard.key(ofLink: "see https://discord.gg/wingcord") == nil)
        #expect(InviteCard.key(ofLink: "https://discord.gg/") == nil)
    }

    @Test("Discord's words, inside the last week, for a server that hasn't gone yet")
    func expiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func words(in seconds: TimeInterval, kind: InviteCard.Kind = .server) -> String? {
            InviteCard(code: "x", kind: kind, name: "n", expiresAt: now.addingTimeInterval(seconds)).expiryWords(now: now)
        }
        #expect(words(in: 3 * 86_400 + 600) == "Invite expires in 3 days")
        #expect(words(in: 86_400) == "Invite expires in 1 day")
        #expect(words(in: 2 * 3_600) == "Invite expires in 2 hours")
        #expect(words(in: 90) == "Invite expires in 1 minute")
        #expect(words(in: 10) == "Invite expires in 1 minute")
        #expect(words(in: -10) == nil)
        #expect(words(in: 8 * 86_400) == nil)
        #expect(words(in: 3_600, kind: .groupDirectMessage) == nil)
        #expect(InviteCard(code: "x", kind: .server, name: "n").expiryWords(now: now) == nil)
    }

    @Test("The splash is the invite's own picture, at a size the CDN serves")
    func splash() throws {
        let card = InviteCard(code: "x", kind: .server, guildID: GuildID(rawValue: 7), name: "n", splashHash: "abc")
        let url = try #require(card.splashURL(width: 1040))
        #expect(url.absoluteString.hasPrefix("https://cdn.discordapp.com/splashes/7/abc.webp?size="))
        #expect(InviteCard(code: "x", kind: .server, guildID: GuildID(rawValue: 7), name: "n").splashURL(width: 1040) == nil)
    }
}
