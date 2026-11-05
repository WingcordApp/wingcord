import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// What docs/FORUMS-INVITES.md put on the wire, or reads off it. None of this is
/// captured yet: it's what Discord's web bundle writes and reads, pinned here so a
/// real account's first run has one less thing to be wrong about.
@Suite("Forums and invites on the wire")
struct ForumsInvitesWireTests {

    private static let channelReply = """
    {"id":"9","type":11,"guild_id":"2","parent_id":"1","name":"A post"}
    """

    private static let messageReply = """
    {"id":"5","channel_id":"5","type":0,"content":"words",
     "author":{"id":"1","username":"ana"},
     "timestamp":"2026-09-10T04:47:52.192000+00:00",
     "attachments":[{"id":"777","filename":"new.png","url":"https://a.example/new.png",
                     "proxy_url":"https://a.example/p/new.png","size":1,"width":10,"height":10}],
     "embeds":[],"mentions":[],"mention_roles":[],"pinned":false,"mention_everyone":false,"tts":false}
    """

    // MARK: A post

    @Test("A post goes to the forum with nested fields, its message inside it")
    func createPost() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.channelReply)
        let post = try await rest.createForumPost(
            in: ChannelID(rawValue: 1),
            name: "A post",
            content: "words",
            tags: [ForumTagID(rawValue: 42)],
            autoArchiveMinutes: 10_080,
            stickerIDs: [77],
            attachments: [
                UploadedAttachment(id: "0", filename: "a.png", uploadedFilename: "u/a.png", isThumbnail: true),
                UploadedAttachment(id: "1", filename: "b.png", uploadedFilename: "u/b.png"),
            ]
        )
        #expect(post.id == ChannelID(rawValue: 9))

        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/channels/1/threads")
        #expect(request.query["use_nested_fields"] == "true")
        #expect(request.json?["name"] as? String == "A post")
        #expect(request.json?["auto_archive_duration"] as? Int == 10_080)
        #expect(request.json?["applied_tags"] as? [String] == ["42"])
        let message = try #require(request.json?["message"] as? [String: Any])
        #expect(message["content"] as? String == "words")
        #expect(message["sticker_ids"] as? [String] == ["77"])
        let files = try #require(message["attachments"] as? [[String: Any]])
        #expect(files[0]["uploaded_filename"] as? String == "u/a.png")
        #expect(files[0]["is_thumbnail"] as? Bool == true)
        #expect(files[1]["is_thumbnail"] == nil, "only the chosen one says so")
    }

    @Test("A post with nothing but words sends no empty lists")
    func createPlainPost() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.channelReply)
        _ = try await rest.createForumPost(
            in: ChannelID(rawValue: 1), name: "A post", content: "words", tags: [], autoArchiveMinutes: 4_320
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        let message = try #require(request.json?["message"] as? [String: Any])
        #expect(message["sticker_ids"] == nil)
        #expect(message["attachments"] == nil)
    }

    @Test("Adding to a message lists what it keeps, then what's new: one left out is deleted")
    func addAttachments() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.messageReply)
        let message = try await rest.addAttachments(
            [UploadedAttachment(id: "0", filename: "new.png", uploadedFilename: "u/new.png")],
            keeping: [
                WingcordCore.Attachment(id: AttachmentID(rawValue: 31), filename: "old.txt", url: "u", proxyURL: "p"),
            ],
            to: MessageID(rawValue: 5),
            in: ChannelID(rawValue: 5)
        )
        #expect(message.attachments.first?.filename == "new.png")

        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v9/channels/5/messages/5")
        let files = try #require(request.json?["attachments"] as? [[String: Any]])
        #expect(files.count == 2)
        #expect(files[0]["id"] as? String == "31")
        #expect(files[0]["filename"] as? String == "old.txt")
        #expect(files[1]["uploaded_filename"] as? String == "u/new.png")
        #expect(request.json?["content"] == nil, "the words stay in the composer")
    }

    @Test("IS_THUMBNAIL on an attachment is bit 2")
    func thumbnailFlag() throws {
        func attachment(flags: Int) throws -> WingcordCore.Attachment {
            let json = """
            {"id":"1","filename":"a.png","url":"u","proxy_url":"p","size":1,"flags":\(flags)}
            """
            return try JSONDecoder().decode(AttachmentDTO.self, from: Data(json.utf8)).domain
        }
        #expect(try attachment(flags: 2).isThumbnail)
        #expect(try attachment(flags: 2 | 32).isThumbnail)
        #expect(try !attachment(flags: 32).isThumbnail)
        #expect(try !attachment(flags: 0).isThumbnail)
    }

    // MARK: How many are new

    /// **Op 28, and it has to be.** The gateway closes the socket on an op it doesn't
    /// know.
    @Test("Asking how many are new is op 28, in the web client's fields")
    func forumUnreadsRequest() throws {
        let request = ForumUnreadsRequest(
            guildID: GuildID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            threads: [(ChannelID(rawValue: 3), MessageID(rawValue: 4))]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: encoder.encode(request), encoding: .utf8))
        #expect(json == #"{"d":{"channel_id":"2","guild_id":"1","threads":[{"ack_message_id":"4","thread_id":"3"}]},"op":28}"#)
    }

    private func update(_ json: String) throws -> GatewayUpdate? {
        GatewayUpdate(try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8)).payload)
    }

    @Test("The answer holds the posts the server could count")
    func forumUnreads() throws {
        let frame = """
        {"op":0,"s":5,"t":"FORUM_UNREADS","d":{"channel_id":"1","threads":[
            {"thread_id":"2","count":3},{"thread_id":"4","missing":true}]}}
        """
        guard case .forumUnreads(let channelID, let counts)? = try update(frame) else {
            Issue.record("not decoded as forum unreads")
            return
        }
        #expect(channelID == ChannelID(rawValue: 1))
        #expect(counts == [ChannelID(rawValue: 2): 3])
    }

    @Test("Refused, the answer is dropped whole, as Discord's is")
    func forumUnreadsRefused() throws {
        let frame = """
        {"op":0,"s":5,"t":"FORUM_UNREADS","d":{"channel_id":"1","permission_denied":true,"threads":[
            {"thread_id":"2","count":3}]}}
        """
        #expect(try update(frame) == nil)
    }

    // MARK: Who else's post

    @Test("Only a thread that didn't exist a moment ago says it's new")
    func newlyCreated() throws {
        func frame(_ extra: String) -> String {
            """
            {"op":0,"s":5,"t":"THREAD_CREATE","d":{"id":"9","type":11,"guild_id":"2","parent_id":"1","name":"p"\(extra)}}
            """
        }
        guard case .threadUpserted(_, let isNew, _)? = try update(frame(#","newly_created":true"#)) else {
            Issue.record("not decoded as a thread")
            return
        }
        #expect(isNew)
        guard case .threadUpserted(_, let isOld, _)? = try update(frame("")) else {
            Issue.record("not decoded as a thread")
            return
        }
        #expect(!isOld)
    }

    // MARK: The invite sheet

    private static let invite = """
    {"type":0,"code":"abc","is_nickname_changeable":true,"flags":1,
     "guild":{"id":"1","name":"S","splash":"sp","banner":null,"icon":null,"features":[]},
     "guild_id":"1",
     "roles":[{"id":"5","name":"Crafter","color":5763719},{"id":"6","color":0},{"name":"no id at all"}],
     "approximate_member_count":10,"approximate_presence_count":3}
    """

    @Test("What the sheet draws comes off the invite, and a role it can't read costs only that role")
    func inviteFields() throws {
        let card = try #require(try JSONDecoder().decode(InviteDTO.self, from: Data(Self.invite.utf8)).card)
        #expect(card.isNicknameChangeable)
        #expect(card.isGuestInvite)
        #expect(card.grantedRoles.map(\.id) == [RoleID(rawValue: 5), RoleID(rawValue: 6)])
        #expect(card.grantedRoles[0].name == "Crafter")
        #expect(card.grantedRoles[0].colorValue == 5_763_719)
        #expect(card.grantedRoles[1].colorValue == nil, "0 is no colour")
    }

    @Test("An invite that says none of it is a plain one")
    func plainInvite() throws {
        let plain = #"{"type":0,"code":"abc","guild":{"id":"1","name":"S","features":[]},"guild_id":"1"}"#
        let card = try #require(try JSONDecoder().decode(InviteDTO.self, from: Data(plain.utf8)).card)
        #expect(!card.isNicknameChangeable)
        #expect(!card.isGuestInvite)
        #expect(card.grantedRoles.isEmpty)
    }

    @Test("Activity, as the sheet starts it: held back everywhere, or in a server over 200")
    func activityDefault() {
        #expect(!ActivitySharingScope.unset.restricts(memberCount: 5_000))
        #expect(!ActivitySharingScope.everywhere.restricts(memberCount: 5_000))
        #expect(ActivitySharingScope.friendsOnly.restricts(memberCount: 5))
        #expect(ActivitySharingScope.smallServersOnly.restricts(memberCount: 201))
        #expect(!ActivitySharingScope.smallServersOnly.restricts(memberCount: 200))
        #expect(!ActivitySharingScope.smallServersOnly.restricts(memberCount: nil))
    }
}
