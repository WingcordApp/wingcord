import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Threads and forum boards.
///
/// Every payload below is captured — `forums.har` and `threads.har`,
/// 2026-09-04 — and trimmed only of fields nothing reads. Two of these routes
/// are documented nowhere at all (`post-data`, and the `@me/settings` PATCH), so
/// a decoder written against a remembered shape would not fail loudly: it would
/// draw a board that is confidently wrong.
@Suite("Threads and forums")
struct ThreadDecodeTests {

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFraction.date(from: text) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(), debugDescription: "bad date \(text)"
            )
        }
        return decoder
    }

    // MARK: A forum board

    /// One page of `#bug-reports`, as `threads/search` returned it.
    ///
    /// The post is archived AND locked, carries three tags, and reports
    /// `message_count` and `total_message_sent` as the same number — which is
    /// what makes it a good witness for `threadMessageCount` not double-counting.
    private let searchPage = """
    {"threads":[
      {"id":"1539353835630996362","type":11,"last_message_id":"1539740462984724480",
       "flags":0,"guild_id":"1520000000000000001",
       "name":"shift+delete doesn't bypass delete message prompt",
       "parent_id":"1528179084432292239","rate_limit_per_user":0,
       "bitrate":64000,"user_limit":0,"rtc_region":null,
       "owner_id":"811641072529494819",
       "thread_metadata":{"archived":true,
         "archive_timestamp":"2026-08-19T20:58:53.616000+00:00",
         "auto_archive_duration":4320,"locked":true,
         "create_timestamp":"2026-08-18T19:22:34.225000+00:00"},
       "message_count":4,"member_count":2,"total_message_sent":4,
       "applied_tags":["1528179216382813544","1530292345274226551","1530198627013350057"],
       "member_ids_preview":["811641072529494819","1530180517157977713"],
       "owner":{"nick":null,"roles":["1528177364122731230"],
         "joined_at":"2026-07-24T21:24:00.624000+00:00",
         "user":{"id":"811641072529494819","username":"sn0wf4ll","global_name":"若葉",
           "avatar":"8b43610c8c2330aff5a1d44d2437ead1","discriminator":"0"}}}],
     "members":[
      {"id":"1533566816294905396","user_id":"987654321987654321",
       "join_timestamp":"2026-08-02T20:07:01.320000+00:00","flags":1,
       "muted":false,"mute_config":null}],
     "first_messages":[
      {"id":"1539353835630996362","type":0,"content":":^",
       "channel_id":"1539353835630996362","timestamp":"2026-08-18T19:22:34.225000+00:00",
       "flags":0,"pinned":false,"mention_everyone":false,"tts":false,
       "author":{"id":"811641072529494819","username":"sn0wf4ll","global_name":"若葉",
         "avatar":"8b43610c8c2330aff5a1d44d2437ead1","discriminator":"0"},
       "attachments":[],"embeds":[],"mentions":[],"mention_roles":[]}],
     "has_more":true,"total_results":36}
    """

    @Test("A search page decodes into posts, memberships and previews")
    func searchPageDecodes() throws {
        let dto = try Self.decoder().decode(
            ThreadSearchDTO.self, from: Data(searchPage.utf8)
        )
        let page = dto.domain(parentID: ChannelID(rawValue: 1_528_179_084_432_292_239))

        #expect(page.hasMore)
        // The forum's total, which the page length cannot be derived from.
        #expect(page.totalResults == 36)
        #expect(page.posts.count == 1)

        let post = try #require(page.posts.first)
        #expect(post.kind == .publicThread)
        #expect(post.name == "shift+delete doesn't bypass delete message prompt")
        #expect(post.parentID == ChannelID(rawValue: 1_528_179_084_432_292_239))
        #expect(post.appliedTags.count == 3)
        #expect(post.memberCount == 2)
        #expect(post.totalMessageSent == 4)
        // Both counts agree here, so the larger-of-two must not add them.
        #expect(post.threadMessageCount == 4)

        let metadata = try #require(post.threadMetadata)
        #expect(metadata.isArchived)
        #expect(metadata.isLocked)
        #expect(metadata.autoArchiveMinutes == 4320)
        #expect(metadata.createdAt != nil)
    }

    @Test("A post's opening message keys on the post, not the forum")
    func firstMessageKeysOnPost() throws {
        let dto = try Self.decoder().decode(
            ThreadSearchDTO.self, from: Data(searchPage.utf8)
        )
        let forumID = ChannelID(rawValue: 1_528_179_084_432_292_239)
        let page = dto.domain(parentID: forumID)
        let postID = ChannelID(rawValue: 1_539_353_835_630_996_362)

        // `channel_id` on a post's opening message is the post's own id. Keying
        // it on the forum would collapse every preview onto one entry.
        #expect(page.firstMessages[postID]?.content == ":^")
        #expect(page.firstMessages[forumID] == nil)
    }

    @Test("The owner arrives as both a user and a guild member")
    func ownerSplitsIntoUserAndMember() throws {
        let dto = try Self.decoder().decode(
            ThreadSearchDTO.self, from: Data(searchPage.utf8)
        )
        let page = dto.domain(parentID: ChannelID(rawValue: 1_528_179_084_432_292_239))
        let ownerID = UserID(rawValue: 811_641_072_529_494_819)

        #expect(page.authors[ownerID]?.username == "sn0wf4ll")
        // The member half is what a byline's colour comes from.
        #expect(page.members[ownerID]?.roleIDs.isEmpty == false)
    }

    @Test("Only the account's own memberships come back, and they are followed threads")
    func membershipsDecode() throws {
        let dto = try Self.decoder().decode(
            ThreadSearchDTO.self, from: Data(searchPage.utf8)
        )
        let page = dto.domain(parentID: ChannelID(rawValue: 1_528_179_084_432_292_239))

        #expect(page.memberships.count == 1)
        let membership = try #require(page.memberships.first)
        #expect(membership.id == ChannelID(rawValue: 1_533_566_816_294_905_396))
        // Flags 1 is HAS_INTERACTED alone — no notification bit — which reads as
        // the middle setting rather than as "nothing".
        #expect(membership.flags == .hasInteracted)
        #expect(membership.notification == .onlyMentions)
        #expect(!membership.isMutedNow())
    }

    // MARK: Notification settings

    /// The reply to `PATCH .../thread-members/@me/settings` with `{"flags":2}`.
    ///
    /// **The request sent 2 and the reply says 3.** That is the whole reason
    /// this client sends one bit and never the member's whole field: bit 0 is
    /// the server's own and it ORs it back in.
    @Test("The server ORs HAS_INTERACTED back into a notification write")
    func notificationReplyKeepsInteractedBit() throws {
        let json = """
        {"id":"1521943196534020354","user_id":"987654321987654321",
         "join_timestamp":"2026-09-04T14:21:55.866000+00:00","flags":3,
         "muted":false,"mute_config":null}
        """
        let dto = try Self.decoder().decode(ThreadMemberDTO.self, from: Data(json.utf8))
        let member = dto.domain(
            threadID: ChannelID(rawValue: 1_521_943_196_534_020_354),
            userID: UserID(rawValue: 987_654_321_987_654_321)
        )

        #expect(member.flags.contains(.hasInteracted))
        #expect(member.flags.contains(.allMessages))
        #expect(member.notification == .allMessages)
        // And what this client would send back is the one bit, not the three.
        #expect(ThreadNotification.allMessages.wireFlags.rawValue == 2)
        #expect(ThreadNotification.onlyMentions.wireFlags.rawValue == 4)
        #expect(ThreadNotification.nothing.wireFlags.rawValue == 8)
    }

    @Test("A member with no notification bit reads as Only @mentions")
    func bareMemberFallsBackToMentions() {
        #expect(ThreadNotification(flags: []) == .onlyMentions)
        #expect(ThreadNotification(flags: .hasInteracted) == .onlyMentions)
        #expect(ThreadNotification(flags: [.hasInteracted, .noMessages]) == .nothing)
    }

    // MARK: Muting

    /// The reply to a fifteen-minute mute, and to taking it off again.
    @Test("A mute carries its window, and unmuting nulls the config")
    func muteDecodes() throws {
        let muted = """
        {"id":"1545428245025247494","user_id":"987654321987654321",
         "join_timestamp":"2026-09-04T14:01:28.342000+00:00","flags":1,"muted":true,
         "mute_config":{"end_time":"2026-09-04T14:16:42+00:00","selected_time_window":900}}
        """
        let dto = try Self.decoder().decode(ThreadMemberDTO.self, from: Data(muted.utf8))
        let member = dto.domain(
            threadID: ChannelID(rawValue: 1_545_428_245_025_247_494),
            userID: UserID(rawValue: 987_654_321_987_654_321)
        )
        let config = try #require(member.muteConfig)
        #expect(config.selectedTimeWindow == 900)
        #expect(MuteDuration.fifteenMinutes.rawValue == 900)

        // **A lapsed mute is not un-muted on the wire.** Discord leaves `muted`
        // true and lets the end time pass, so a client reading the flag alone
        // shows the thread muted for ever.
        let end = try #require(config.endTime)
        #expect(member.isMutedNow(at: end.addingTimeInterval(-60)))
        #expect(!member.isMutedNow(at: end.addingTimeInterval(60)))

        let unmuted = """
        {"id":"1545428245025247494","user_id":"987654321987654321",
         "join_timestamp":"2026-09-04T14:01:28.342000+00:00","flags":1,
         "muted":false,"mute_config":null}
        """
        let off = try Self.decoder()
            .decode(ThreadMemberDTO.self, from: Data(unmuted.utf8))
            .domain(
                threadID: ChannelID(rawValue: 1_545_428_245_025_247_494),
                userID: UserID(rawValue: 987_654_321_987_654_321)
            )
        #expect(!off.isMutedNow())
        #expect(off.muteConfig == nil)
    }

    @Test("An indefinite mute has a window of -1 and no end time")
    func indefiniteMute() {
        #expect(MuteDuration.untilTurnedBackOn.rawValue == -1)
        #expect(MuteDuration.untilTurnedBackOn.endTime() == nil)
        // With no end time there is nothing to expire against.
        #expect(ThreadMuteConfig(endTime: nil, selectedTimeWindow: -1).isActive(at: .distantFuture))
    }

    // MARK: post-data

    /// The undocumented batch route, as `forums.har` shows it: a reply keyed by
    /// thread id, each entry holding the opening message and the owner.
    @Test("post-data decodes into a preview per post")
    func postDataDecodes() throws {
        let json = """
        {"threads":{"1534597441621588395":{
          "first_message":{"id":"1534597441621588395","type":0,
            "content":"this is pretty important","channel_id":"1534597441621588395",
            "timestamp":"2026-08-05T16:22:21.524000+00:00","flags":0,"pinned":false,
            "mention_everyone":false,"tts":false,
            "author":{"id":"708402754576396841","username":"moony",
              "global_name":"ᴍᴏᴏɴʏ","avatar":"b2856c02024cb92e69541b1fa37e2c5d",
              "discriminator":"0"},
            "attachments":[],"embeds":[],"mentions":[],"mention_roles":[]},
          "owner":{"nick":null,"roles":[],
            "user":{"id":"708402754576396841","username":"moony",
              "avatar":"b2856c02024cb92e69541b1fa37e2c5d","discriminator":"0"}}}}}
        """
        let dto = try Self.decoder().decode(PostDataDTO.self, from: Data(json.utf8))
        let entry = try #require(dto.threads?["1534597441621588395"])
        #expect(entry.first_message?.content == "this is pretty important")
        #expect(entry.owner?.user?.username == "moony")
        // The key is a string on the wire and a channel id in the store.
        #expect(ChannelID("1534597441621588395") != nil)
    }

    // MARK: Forum tags

    /// `available_tags` is **not** in either capture — it rides the channel
    /// object over the gateway, and a HAR carries no WebSocket frames. The shape
    /// is the documented one, and this pins it so the join from `applied_tags`
    /// cannot silently rot.
    @Test("A forum's tags decode, and one of the two emoji fields is always null")
    func forumTagsDecode() throws {
        let json = """
        {"id":"1528179084432292239","type":15,"name":"bug-reports",
         "default_sort_order":0,"default_forum_layout":1,"flags":16,
         "available_tags":[
           {"id":"1528179216382813544","name":"Functionality","moderated":false,
            "emoji_id":"1530292323184126375","emoji_name":null},
           {"id":"1530198627013350057","name":"Planned","moderated":true,
            "emoji_id":null,"emoji_name":"🗓️"}],
         "default_reaction_emoji":{"emoji_id":null,"emoji_name":"🐛"}}
        """
        let channel = try Self.decoder()
            .decode(ChannelDTO.self, from: Data(json.utf8))
            .domain()

        #expect(channel.kind == .forum)
        #expect(channel.isForumLike)
        // `flags: 16` is REQUIRE_TAG — a post here must carry one.
        #expect(channel.requiresTag)
        #expect(!channel.isPinnedPost)
        #expect(channel.defaultSortOrder == .recentActivity)
        #expect(channel.defaultForumLayout == .list)
        #expect(channel.availableTags.count == 2)

        let custom = try #require(channel.availableTags.first)
        #expect(custom.name == "Functionality")
        #expect(custom.emoji?.isCustom == true)

        let unicode = channel.availableTags[1]
        #expect(unicode.isModerated)
        #expect(unicode.emoji?.isCustom == false)
        #expect(unicode.emoji?.name == "🗓️")

        #expect(channel.defaultReaction?.name == "🐛")
    }

    @Test("Discord's layout 0 resolves to the list rather than a third state")
    func layoutZeroResolves() {
        #expect(ForumLayout(rawChannelValue: 0) == .list)
        #expect(ForumLayout(rawChannelValue: 1) == .list)
        #expect(ForumLayout(rawChannelValue: 2) == .gallery)
    }

    @Test("A sort order's query spelling is not its integer")
    func sortOrderQueryValues() {
        // The channel object stores an integer; `threads/search` wants a string,
        // and the capture shows `last_message_time` rather than anything derived
        // from the enum's name.
        #expect(ForumSortOrder.recentActivity.queryValue == "last_message_time")
        #expect(ForumSortOrder.creationDate.queryValue == "creation_time")
        #expect(TagMatching.some.rawValue == "match_some")
        #expect(TagMatching.all.rawValue == "match_all")
    }

    // MARK: Gateway

    @Test("THREAD_CREATE decodes the channel and its two extra fields together")
    func threadCreateDecodes() throws {
        let json = """
        {"id":"1545428245025247494","type":11,"guild_id":"1520000000000000001",
         "parent_id":"1528179084432292239","name":"Hidden channels Bug",
         "owner_id":"987654321987654321","message_count":1,"member_count":1,
         "total_message_sent":1,"applied_tags":["1528179216382813544"],
         "thread_metadata":{"archived":false,"auto_archive_duration":4320,
           "locked":false,"archive_timestamp":"2026-09-04T14:01:28.000000+00:00"},
         "newly_created":true,
         "member":{"join_timestamp":"2026-09-04T14:01:28.342000+00:00","flags":1}}
        """
        let dto = try Self.decoder().decode(ThreadCreateDTO.self, from: Data(json.utf8))

        // The channel is decoded from the same container, not a nested key.
        #expect(dto.channel.name == "Hidden channels Bug")
        #expect(dto.channel.applied_tags?.count == 1)
        #expect(dto.newly_created == true)

        // The nested membership omits `id` and `user_id` because both are
        // implied — which is the whole reason the socket has to supply them.
        let member = try #require(dto.member)
        #expect(member.id == nil)
        #expect(member.user_id == nil)
        let resolved = member.domain(
            threadID: ChannelID(rawValue: 1_545_428_245_025_247_494),
            userID: UserID(rawValue: 987_654_321_987_654_321)
        )
        #expect(resolved.id == ChannelID(rawValue: 1_545_428_245_025_247_494))
        #expect(resolved.userID == UserID(rawValue: 987_654_321_987_654_321))
    }

    @Test("THREAD_DELETE is a partial channel with no name")
    func threadDeleteDecodes() throws {
        let json = """
        {"id":"1545428245025247494","guild_id":"1520000000000000001",
         "parent_id":"1528179084432292239","type":11}
        """
        let dto = try Self.decoder().decode(ThreadDeleteDTO.self, from: Data(json.utf8))
        #expect(dto.id == ChannelID(rawValue: 1_545_428_245_025_247_494))
        #expect(dto.parent_id == ChannelID(rawValue: 1_528_179_084_432_292_239))
    }

    // MARK: The Threads flyout

    /// The toolbar's Threads flyout, opened on an **announcement** channel.
    ///
    /// **This overturns the published reference.** `threads/search` is
    /// documented as forum- and media-only; `threads toolbar.har` sends it at
    /// `#unstable-releases` — a type-5 announcement channel — with byte-identical
    /// parameters to a forum board's, and gets 307 results back. So the flyout
    /// and the board share one route, one fetch and one pager.
    ///
    /// The one difference in the reply is that this form carries **no
    /// `first_messages`**, which is why that field is optional and why nothing
    /// downstream may assume a preview exists.
    @Test("threads/search answers for a text channel, without first_messages")
    func textChannelThreadSearch() throws {
        let json = """
        {"threads":[
          {"id":"1521943196534020354","type":10,
           "last_message_id":"1528517632624731806","flags":0,
           "guild_id":"774352792659691746","name":"Iris 1.11.2 Beta 1",
           "parent_id":"883067831487134463","rate_limit_per_user":0,
           "owner_id":"366702774403989504",
           "thread_metadata":{"archived":true,
             "archive_timestamp":"2026-08-18T21:53:04.133000+00:00",
             "auto_archive_duration":10080,"locked":false,
             "create_timestamp":"2026-07-01T18:19:02.325000+00:00"},
           "message_count":720,"member_count":50,"total_message_sent":728,
           "member_ids_preview":["363450540096547977","358032084213393543",
             "544194482528981400","366702774403989504","413535697256054598"],
           "owner":{"nick":null,"roles":["1087548257416565860"],
             "joined_at":"2020-11-06T22:22:37.166000+00:00",
             "user":{"id":"366702774403989504","username":"lina","discriminator":"0"}}}],
         "members":[
          {"id":"1521943196534020354","user_id":"987654321987654321",
           "join_timestamp":"2026-09-04T14:21:55.866000+00:00","flags":9,
           "muted":false,"mute_config":null}],
         "has_more":true,"total_results":307}
        """
        let dto = try Self.decoder().decode(ThreadSearchDTO.self, from: Data(json.utf8))
        let page = dto.domain(parentID: ChannelID(rawValue: 883_067_831_487_134_463))

        #expect(page.totalResults == 307)
        #expect(page.hasMore)
        // Absent, not empty-and-wrong: a text channel's reply carries none.
        #expect(page.firstMessages.isEmpty)

        let thread = try #require(page.posts.first)
        #expect(thread.kind == .announcementThread)
        #expect(thread.memberCount == 50)
        // Five bare ids, for the row's avatar stack.
        #expect(thread.memberIDsPreview.count == 5)
        #expect(thread.threadMessageCount == 720)

        // The owner still splits into a user and a member, which is where
        // "Started by IMS" comes from.
        #expect(page.authors[UserID(rawValue: 366_702_774_403_989_504)]?.username == "lina")

        // `flags: 9` is HAS_INTERACTED | NO_MESSAGES — a followed thread the
        // reader has set to notify them of nothing.
        let membership = try #require(page.memberships.first)
        #expect(membership.flags.contains(.hasInteracted))
        #expect(membership.notification == .nothing)
    }

    /// Typing into the Threads flyout's field.
    ///
    /// **A request, not a filter, and its own query shape.** Captured,
    /// `threads toolbar1.har`: the field sends
    /// `?name=the+sun&tag_setting=match_some` and nothing else — no `archived`,
    /// no `sort_by`, no `sort_order`, no `limit`, no `offset`. The hit is a
    /// thread from 2025, far older than the hundred and fifty rows that had been
    /// scrolled in, which is what proves the server searches the whole channel
    /// rather than the pages the client holds.
    @Test("A name search returns one page, unpaged, from the whole channel")
    func threadNameSearch() throws {
        let json = """
        {"threads":[
          {"id":"1435313430672119032","type":10,
           "last_message_id":"1437634372440420240","flags":0,
           "guild_id":"774352792659691746","name":"the sun is not a real object",
           "parent_id":"883067831487134463","rate_limit_per_user":0,
           "owner_id":"366702774403989504",
           "thread_metadata":{"archived":true,
             "archive_timestamp":"2025-12-11T02:54:18.658000+00:00",
             "auto_archive_duration":10080,"locked":false,
             "create_timestamp":"2025-11-04T17:03:18.008000+00:00"},
           "message_count":61,"member_count":16,"total_message_sent":62,
           "member_ids_preview":["174206282014431774","513291562327021859",
             "172807592412111480","366702774403989504","174322727600521881"]}],
         "members":[],"has_more":false,"total_results":1}
        """
        let dto = try Self.decoder().decode(ThreadSearchDTO.self, from: Data(json.utf8))
        let page = dto.domain(parentID: ChannelID(rawValue: 883_067_831_487_134_463))

        #expect(page.posts.count == 1)
        #expect(page.totalResults == 1)
        // No paging to follow: the query carries no offset to advance, and the
        // reply says there is nothing after this.
        #expect(!page.hasMore)
        #expect(page.memberships.isEmpty)

        let hit = try #require(page.posts.first)
        #expect(hit.name == "the sun is not a real object")
        // A substring match rather than a prefix: "the sun" found a name that
        // continues past it.
        #expect(hit.name.hasPrefix("the sun"))
        #expect(hit.threadMessageCount == 61)
        // 16 in the thread against five faces — below the cap, so the badge is
        // exact.
        #expect(hit.memberCount == 16)
        #expect(hit.memberIDsPreview.count == 5)
    }

    // MARK: The chip under a message

    /// A message from `#unstable-releases` with its thread nested inline.
    ///
    /// **This is where the chip's count comes from, and it settles which field
    /// it is.** The thread reports `message_count: 720` beside
    /// `total_message_sent: 728`, and Discord's own chip reads "720 Messages" —
    /// so the number people see excludes deleted messages rather than counting
    /// everything ever sent.
    @Test("A message carries its thread inline, and the chip counts 720 not 728")
    func messageThreadDecodes() throws {
        let json = """
        {"id":"1521943196534020354","type":0,"content":"@[Testers]",
         "channel_id":"883067831487134463","timestamp":"2026-07-01T18:18:59.000000+00:00",
         "flags":0,"pinned":false,"mention_everyone":false,"tts":false,
         "author":{"id":"366702774403989504","username":"lina","discriminator":"0"},
         "attachments":[],"embeds":[],"mentions":[],"mention_roles":[],
         "thread":{"id":"1521943196534020354","type":10,
           "last_message_id":"1528517632624731806","flags":0,
           "guild_id":"774352792659691746","name":"Iris 1.11.2 Beta 1",
           "parent_id":"883067831487134463","rate_limit_per_user":0,
           "owner_id":"366702774403989504",
           "thread_metadata":{"archived":true,
             "archive_timestamp":"2026-08-18T21:53:04.133000+00:00",
             "auto_archive_duration":10080,"locked":false,
             "create_timestamp":"2026-07-01T18:19:02.325000+00:00"},
           "message_count":720,"member_count":50,"total_message_sent":728}}
        """
        let dto = try Self.decoder().decode(MessageDTO.self, from: Data(json.utf8))
        let message = dto.domain

        let thread = try #require(message.thread)
        #expect(thread.name == "Iris 1.11.2 Beta 1")
        #expect(thread.messageCount == 720)
        #expect(thread.isArchived)
        // A thread off a message takes the source message's own id, which is
        // why the chip needs no separate pointer back.
        #expect(thread.id.rawValue == message.id.rawValue)

        // And the whole channel comes through too, so clicking the chip has
        // something to open.
        let channel = try #require(dto.thread?.domain())
        #expect(channel.kind == .announcementThread)
        #expect(channel.parentID == ChannelID(rawValue: 883_067_831_487_134_463))
        #expect(channel.threadMessageCount == 720)
        #expect(channel.threadMetadata?.autoArchiveMinutes == 10080)
    }

    @Test("An ordinary message allocates no thread and no payload box")
    func messageWithoutThread() throws {
        let json = """
        {"id":"1","type":0,"content":"hello","channel_id":"2",
         "timestamp":"2026-07-01T18:18:59.000000+00:00","flags":0,"pinned":false,
         "mention_everyone":false,"tts":false,
         "author":{"id":"3","username":"a","discriminator":"0"},
         "attachments":[],"embeds":[],"mentions":[],"mention_roles":[]}
        """
        let message = try Self.decoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
        #expect(message.thread == nil)
        // The box exists only for messages that are already unusual — a thread
        // must not be what makes every plain message allocate one.
        #expect(message.payload == nil)
    }

    @Test("A THREAD_LIST_SYNC with no channel_ids means the whole guild")
    func listSyncNilParents() throws {
        let json = """
        {"guild_id":"1520000000000000001","threads":[],"members":[]}
        """
        let dto = try Self.decoder().decode(ThreadListSyncDTO.self, from: Data(json.utf8))
        // Nil, not empty. A client reading it as "no channels" keeps every
        // stale thread the event was sent to clear.
        #expect(dto.channel_ids == nil)
        #expect(dto.guild_id != nil)
    }
}
