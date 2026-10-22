import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A Discord clip in chat (docs/CLIPS-PRESENCE.md, Phase 4.5): what its tile
/// and its player draw, its timeline comments, and the library's filters
/// (Phase 4.2).
@MainActor
@Suite("Clip player")
struct ClipPlayerTests {

    private let me = UserID(rawValue: 1)
    private let sam = UserID(rawValue: 2)
    private let dm = ChannelID(rawValue: 30)
    private let clipMessage = MessageID(rawValue: 100)
    private let clipFile = AttachmentID(rawValue: 500)

    private func user(_ id: UInt64, _ name: String) -> User {
        User(id: UserID(rawValue: id), username: name)
    }

    private func clip(participants: Int = 2, title: String? = "clutch") -> AttachmentClip {
        AttachmentClip(
            title: title, applicationID: 1, applicationName: "Battlefield 6", createdAt: .now,
            participants: (1...participants).map { user(UInt64($0), "p\($0)") },
            timeline: [ClipTimelineEvent(timestampMS: 0, event: .speaking(userID: 2, flags: 1))],
            hasTimelineComments: true
        )
    }

    private func reply(_ id: UInt64, by author: UserID, _ words: String, at milliseconds: Int, on file: AttachmentID? = nil) -> Message {
        Message(
            id: MessageID(rawValue: id), channelID: dm, authorID: author, content: words, kind: .reply,
            payload: MessagePayload(
                reference: MessageReference(messageID: clipMessage, channelID: dm, authorID: sam),
                mediaMention: MediaMention(attachmentID: file ?? clipFile, timestampMS: milliseconds)
            )
        )
    }

    /// A ready model with a conversation holding Sam's clip.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.connectionState = .ready
        model.users[me] = user(1, "alex")
        model.users[sam] = user(2, "kim")
        model.channelIndex.upsert(Channel(id: dm, kind: .directMessage, recipientIDs: [sam]))
        let attachment = Attachment(
            id: clipFile, filename: "clip.mp4", url: "https://cdn/clip.mp4", proxyURL: "https://media/clip.mp4",
            contentType: "video/mp4", size: 1, durationSeconds: 20, clip: clip()
        )
        var box = MessageBox()
        box.messages = [Message(
            id: clipMessage, channelID: dm, authorID: sam, content: "look",
            payload: MessagePayload(attachments: [attachment])
        )]
        model.setMessages(box, in: dm)
        return model
    }

    @Test("A comment that is one emoji is drawn as itself; anything else is words")
    func emoji() {
        #expect(TimelineComment.emoji(in: " 😆 ") == .unicode("😆"))
        #expect(TimelineComment.emoji(in: "👍🏽") == .unicode("👍🏽"))
        guard case .custom(let name, let url) = TimelineComment.emoji(in: "<a:dance:456>") else {
            Issue.record("a custom emoji's tag is an emoji")
            return
        }
        #expect(name == "dance")
        #expect(url?.absoluteString.contains("/emojis/456.") == true)
        #expect(TimelineComment.emoji(in: "<:pog:12>") != nil)
        for words in ["gg", "😆😆", "1", "#", "<:x:notanid>", ""] {
            #expect(TimelineComment.emoji(in: words) == nil, "\(words) is words")
        }
    }

    @Test("The scrubber keeps the higher-ranked of two moments too close to tell apart, in time order")
    func moments() {
        let timeline = [
            ClipTimelineEvent(timestampMS: 9_400, event: .game(type: .multikill, name: "Triple Kill")),
            ClipTimelineEvent(timestampMS: 9_600, event: .emotion(.shouting)),
            ClipTimelineEvent(timestampMS: 4_200, event: .game(type: .kill, name: "Kill")),
            ClipTimelineEvent(timestampMS: 0, event: .speaking(userID: 2, flags: 1)),
            ClipTimelineEvent(timestampMS: 25_000, event: .game(type: .death, name: "Death")),
            ClipTimelineEvent(timestampMS: 10_500, event: .emotion(.laughter)),
        ]
        let marks = ClipMark.moments(in: timeline, duration: 20)
        #expect(marks.map(\.seconds) == [4.2, 9.4, 10.5], "speech is no mark, past the end is dropped, a shout under a triple goes")
        #expect(marks.map(\.title) == ["Kill", "Triple Kill", "LOL"])
        #expect(marks[1].detail == "In-game event")
        #expect(marks[2].detail == "Emotional moment")
        #expect(ClipMark.moments(in: timeline, duration: 0).isEmpty)
    }

    @Test("Timeline comments come from the channel, the reader's sends and the media thread — once each, by moment")
    func comments() throws {
        let model = model()
        model.mutateBox(dm) { box in
            box.messages.append(reply(101, by: sam, "that flank", at: 9_600))
            box.messages.append(reply(102, by: sam, "other clip", at: 1_000, on: AttachmentID(rawValue: 501)))
            let request = OutgoingMessage.Request(content: "gg", replyingTo: clipMessage, mediaMention: MediaMention(attachmentID: clipFile, timestampMS: 2_000))
            let id = MessageID(rawValue: 103)
            box.outbox.append(OutgoingMessage(
                id: id, request: request, echo: model.echo(of: request, id: id, in: dm, author: me),
                state: .sending, files: []
            ))
        }
        // The thread holds its copy of 101 under the same id, and one the
        // channel has not loaded.
        model.clipCommentThreads[clipFile] = [reply(101, by: sam, "that flank", at: 9_600), reply(99, by: sam, "😆", at: 5_000)]

        let comments = model.timelineComments(on: clipFile, in: dm)
        #expect(comments.map(\.id.rawValue) == [103, 99, 101])
        #expect(comments.map(\.timestampMS) == [2_000, 5_000, 9_600])
        #expect(comments[0].isPending)
        #expect(comments[1].emoji == .unicode("😆"))
        #expect(comments[2].authorName == "kim")
        #expect(comments[2].emoji == nil)
    }

    @Test("A timeline comment is a reply to the clip at the moment")
    func send() throws {
        let model = model()
        model.sendTimelineComment("  nice  ", at: 12_345, on: clipFile, of: clipMessage, in: dm, echoesLocally: true)
        let sent = try #require(model.messages(in: dm)?.messages.last)
        #expect(sent.content == "nice")
        #expect(sent.authorID == me)
        #expect(sent.referencedMessageID == clipMessage)
        #expect(sent.mediaMention == MediaMention(attachmentID: clipFile, timestampMS: 12_345))
        #expect(model.timelineComments(on: clipFile, in: dm).map(\.content) == ["nice"])

        // Nothing goes without a session, and nothing empty goes at all.
        model.sendTimelineComment("   ", at: 0, on: clipFile, of: clipMessage, in: dm, echoesLocally: true)
        model.connectionState = .signedOut
        model.sendTimelineComment("late", at: 0, on: clipFile, of: clipMessage, in: dm, echoesLocally: true)
        #expect(model.messages(in: dm)?.messages.count == 2)
    }

    @Test("The clip's people, by the names this account knows them by")
    func faces() {
        let model = model()
        let faces = model.clipFaces(clip(participants: 3), in: dm)
        #expect(faces.map(\.id.rawValue) == [1, 2, 3])
        #expect(faces.map(\.name) == ["alex", "kim", "p3"])
        #expect(faces.allSatisfy { $0.url != nil })
    }

    @Test("A clip's tile: words only from 250 points, four faces and the rest as a count")
    func tileHeader() {
        let wide = ClipTileHeader(clip(participants: 6, title: nil), width: 400)
        #expect(wide.title == "Untitled")
        #expect(wide.subtitle?.hasPrefix("Battlefield 6 · ") == true)
        #expect(wide.faces.count == 4)
        #expect(wide.overflow == 2)

        let frame = CGRect(x: 0, y: 0, width: 400, height: 225)
        let (faces, overflow) = wide.faceRects(in: frame)
        #expect(faces.count == 4)
        #expect(faces.map(\.minX) == faces.map(\.minX).sorted(), "the first face is leftmost")
        if let overflow {
            #expect(overflow.maxX == frame.maxX - 10, "the count sits at the trailing edge")
            #expect(faces[3].maxX < overflow.minX)
        } else {
            Issue.record("six people draw a count")
        }

        let narrow = ClipTileHeader(clip(participants: 2), width: 200)
        #expect(narrow.title == nil && narrow.subtitle == nil)
        #expect(narrow.faces.count == 2 && narrow.overflow == 0)
        #expect(narrow.faceRects(in: frame).overflow == nil)
    }

    /// One message laid out as the transcript lays it.
    private func laidOut(_ message: Message) -> MessageRow? {
        let engine = TimelineLayoutEngine(presentationRevision: 1)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = engine.layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 640,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        guard case .message(let row) = laid.first?.kind else { return nil }
        return row
    }

    @Test("In the transcript a clip draws its header and says it; a comment says its moment")
    func transcript() throws {
        let attachment = Attachment(
            id: clipFile, filename: "clip.mp4", url: "https://cdn/clip.mp4", proxyURL: "https://media/clip.mp4",
            contentType: "video/mp4", size: 1, width: 1280, height: 720, durationSeconds: 20,
            clip: clip(participants: 6)
        )
        let row = try #require(laidOut(Message(
            id: clipMessage, channelID: dm, authorID: sam, content: "",
            payload: MessagePayload(attachments: [attachment])
        )))
        let header = try #require(row.attachments.first?.clip)
        #expect(header.title == "clutch")
        #expect(header.faces.count == 4 && header.overflow == 2)
        #expect(row.accessibilityLabel.contains("Clip, clutch, Battlefield 6, with p1, p2, p3, p4 and 2 more"))

        let comment = try #require(laidOut(reply(104, by: sam, "lmao", at: 9_600)))
        #expect(comment.accessibilityLabel.contains("At 0:09 in the clip"))
        #expect(comment.attachments.isEmpty)
    }

    @Test("Only a video carries its clip into the viewer")
    func mediaItem() {
        let video = Attachment(
            id: clipFile, filename: "a.mp4", url: "https://cdn/a.mp4", proxyURL: "https://media/a.mp4",
            contentType: "video/mp4", size: 1, clip: clip()
        )
        #expect(MediaItem(video, posterWidth: 300)?.clip?.title == "clutch")
        var picture = video
        picture.contentType = "image/png"
        picture.filename = "a.png"
        #expect(MediaItem(picture, posterWidth: 300)?.clip == nil)
    }

    @Test("The library's filters: kind, Discord's dates, the game, favourites, and search over people too")
    func libraryFilter() {
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        let calendar = Calendar(identifier: .gregorian)
        func item(_ name: String, ext: String, daysAgo: Double, game: String?, people: [String] = []) -> ClipLibraryItem {
            let manifest = ClipManifest(
                createdAt: now.addingTimeInterval(-daysAgo * 86_400), duration: 30, title: name,
                game: game.map { ClipGame(applicationID: nil, name: $0) },
                participants: people.enumerated().map { ClipParticipant(userID: UInt64($0.offset), name: $0.element) }
            )
            return ClipLibraryItem(clip: Clip(
                url: URL(filePath: "/clips/\(name).\(ext)"), created: manifest.createdAt, byteCount: 1,
                isScreenshot: ext == "png", manifest: ext == "png" ? nil : manifest
            ))
        }
        let today = item("ace", ext: "mp4", daysAgo: 0.1, game: "Valorant", people: ["Kim"])
        let yesterday = item("bridge", ext: "mp4", daysAgo: 1, game: "Battlefield 6")
        let shot = item("menu", ext: "png", daysAgo: 400, game: nil)
        let all = [today, yesterday, shot]
        func names(_ filter: ClipLibraryFilter, favourites: Set<URL> = []) -> [String] {
            all.filter { filter.matches($0, isFavourite: favourites.contains($0.url), now: now, calendar: calendar) }
                .map(\.clip.name)
        }

        #expect(names(ClipLibraryFilter()) == ["ace", "bridge", "menu"])
        #expect(!ClipLibraryFilter().isActive)
        #expect(names(ClipLibraryFilter(kind: .screenshots)) == ["menu"])
        #expect(names(ClipLibraryFilter(kind: .clips)) == ["ace", "bridge"])
        #expect(names(ClipLibraryFilter(date: .today)) == ["ace"])
        #expect(names(ClipLibraryFilter(date: .yesterday)) == ["bridge"])
        #expect(names(ClipLibraryFilter(date: .lastYear)) == ["menu"])
        #expect(names(ClipLibraryFilter(game: "Battlefield 6")) == ["bridge"])
        #expect(names(ClipLibraryFilter(favouritesOnly: true), favourites: [shot.url]) == ["menu"])
        #expect(names(ClipLibraryFilter(query: "kim")) == ["ace"], "a search finds the people in it")
        #expect(names(ClipLibraryFilter(query: "battle bridge")) == ["bridge"], "every word has to match")
        #expect(ClipLibraryFilter(query: "x").isActive)
    }
}
