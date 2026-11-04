import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// What `--demo` actually contains.
///
/// **A fixture that quietly loses half of itself is the most expensive kind of
/// bug in this tree**, because every surface built against it then looks wrong
/// for a reason that is not in the surface. Two of these landed in one session:
/// the reader's call held one participant where four sections of the fixture
/// describe five, and the private channel list evicted the transcript it had
/// just seeded. Both were invisible until somebody photographed a widget.
@MainActor
@Suite("Demo fixtures")
struct DemoFixtureTests {

    private func model() -> AppModel {
        let model = AppModel()
        DemoFixtures.populate(model)
        return model
    }

    @Test("The reader is in a call with four other people in it")
    func theCallHasItsCast() throws {
        let presentation = try #require(model().voicePresentation)
        #expect(presentation.participants.count == 5)
        // Every mark the tiles and the overlay's roster can draw, at once.
        #expect(presentation.participants.contains { $0.isSilenced })
        #expect(presentation.participants.contains { $0.isDeafened })
        #expect(presentation.participants.contains { $0.canWatch })
        #expect(presentation.participants.contains { $0.isCameraOn })
    }

    @Test("A second room somewhere else is in use, so the overlay's Voice tab has two")
    func roomsElsewhere() {
        let rooms = model().overlaySidebarPresentation.rooms
        #expect(rooms.count >= 2)
        #expect(rooms.contains { $0.isJoined })
        #expect(rooms.contains { !$0.isJoined })
        // One with a ceiling and one without, which are the two shapes the
        // counter has.
        #expect(rooms.contains { $0.limit > 0 })
        #expect(rooms.contains { $0.limit == 0 })
    }

    @Test("The conversation the overlay opens has a transcript behind it")
    func theFirstConversationIsLoaded() throws {
        let model = self.model()
        let channelID = try #require(model.channelIndex.privateChannelIDs().first)
        // `residentChannelLimit` is three, so seeding more transcripts than that
        // silently evicts the earliest — and the earliest is this one.
        #expect(model.messages(in: channelID)?.messages.isEmpty == false)
    }

    @Test("A conversation is named for the other person, not for the reader")
    func conversationsAreNamedForTheOtherPerson() throws {
        let model = self.model()
        let channelID = try #require(model.channelIndex.privateChannelIDs().first)
        let channel = try #require(model.channelIndex[channelID])
        let reader = try #require(model.currentUserID)
        // Discord's `recipients` excludes the account. A fixture that includes
        // it puts the reader's own name in the title of every conversation.
        #expect(!channel.recipientIDs.contains(reader))
        #expect(!model.displayName(of: channel).contains("alex"))
    }

    @Test("Most conversations are read, so the unread dot means something")
    func readStatesExist() {
        let rows = model().overlaySidebarPresentation.conversations
        #expect(rows.contains { $0.isUnread })
        #expect(rows.contains { !$0.isUnread })
        #expect(rows.contains { $0.mentionCount > 0 })
    }

    @Test("Friends fill every band the overlay's list draws")
    func friendsFillTheBands() {
        let sections = model().overlaySidebarPresentation.friends
        let bands = Set(sections.map(\.id))
        #expect(bands.contains(.favorites))
        #expect(bands.contains(.inGame))
        #expect(bands.contains(.online))
        #expect(sections.allSatisfy { !$0.people.isEmpty })
    }

    @Test("The channel the demo opens on has interleaved summaries, and another server has a theme")
    func summariesAndServerTheme() throws {
        let model = self.model()
        let channelID = try #require(model.selectedChannelID)
        #expect(model.summariesApply(to: channelID))
        let summaries = model.summaries(in: channelID)
        #expect(summaries.count >= 3)
        // Newest first, and the stretches overlap — which is what makes the
        // bar's choice of name a choice.
        #expect(zip(summaries, summaries.dropFirst()).allSatisfy {
            $0.startMessageID > $1.startMessageID && $1.endMessageID > $0.startMessageID
        })
        #expect(summaries.allSatisfy { $0.messageCount > 1 && !$0.people.isEmpty })
        #expect(model.channelChrome.canShowSummaries)

        // The demo's own server wears the reader's theme; the themed one is
        // a step away on the rail.
        #expect(model.activeServerTheme == nil)
        let themed = try #require(model.guilds.values.first { $0.theme != nil })
        model.selectedGuildID = themed.id
        #expect(model.activeServerTheme?.theme.resolved == .preset(3))
    }

    // MARK: Phase 2's surfaces

    /// The opening channel's messages above Phase 4's clip — Phase 2's
    /// surfaces sit at the foot of what came before it.
    private func aboveTheClip(in model: AppModel) throws -> ArraySlice<Message> {
        let channelID = try #require(model.selectedChannelID)
        let messages = try #require(model.messages(in: channelID)?.messages)
        // The shared clip itself — not a reply carrying another view of it.
        let clip = try #require(messages.lastIndex { message in
            message.referencedMessageID == nil && message.attachments.contains { $0.clip != nil }
        })
        return messages[..<clip]
    }

    @Test("Two voice invites at the transcript's foot: the crowd's as the channel row, the reader's own as the card")
    func voiceInvites() throws {
        let saved = AppSettings.shared.voiceInviteCardStyle
        defer { AppSettings.shared.voiceInviteCardStyle = saved }
        AppSettings.shared.voiceInviteCardStyle = .asDiscordDecides
        let model = self.model()
        let codes = try aboveTheClip(in: model).suffix(4).flatMap { InviteCard.codes(in: $0.content) }
        // Pixel Forge's server invite follows them (the "+ N more" traits,
        // SHEETS-SETTINGS Phase 1.2) — not a voice invite.
        #expect(codes.filter { $0 != "demo-forge" } == ["demo-crowd", "demo-hangout"])

        let states = model.voiceInviteStates()
        #expect(states.count == 2, "both rooms drawn")
        let crowd = try #require(states.values.first { $0.asChannelRow })
        #expect(crowd.people.count >= 5, "a crowd, so the row counts the rest")
        #expect(crowd.people.contains { $0.isStreaming })
        let own = try #require(states.values.first { !$0.asChannelRow })
        let me = try #require(model.currentUserID)
        #expect(own.people.contains { $0.id == me }, "the reader's own room, so its card is settled")
    }

    @Test("A shared theme, somebody typing with a custom indicator, the reader's own worn")
    func themeAndTyping() throws {
        let model = self.model()
        let channelID = try #require(model.selectedChannelID)
        let last = try #require(try aboveTheClip(in: model).last)
        #expect(last.sharedTheme?.colors.count == 3)
        // Seeded, so Appearance never asks Discord for them in `--demo`.
        #expect(model.accountCustomThemes?.count == 2)
        #expect(model.accountCustomThemes?.contains { $0.isLight } == true)
        #expect(model.ownTypingIndicatorStyle?.isPlain == false)

        let conversation = try #require(model.channelIndex.privateChannelIDs().first)
        let typer = try #require(model.typers(in: conversation).keys.first)
        #expect(model.typingStyle(of: typer)?.suggestion == .yapping)
        #expect(model.channelIndex[conversation]?.recipientIDs.contains(typer) == true, "the other person")
        #expect(model.messages(in: conversation)?.messages.isEmpty == false, "a transcript under it")
        #expect(model.typers(in: channelID).isEmpty, "kept off the channel the demo opens on")
    }

    // MARK: Phase 4's clip

    @Test("A friend's clip at the foot — five people, speech, the game's moments — and two timeline comments on it")
    func sharedClip() throws {
        let model = self.model()
        let channelID = try #require(model.selectedChannelID)
        let messages = try #require(model.messages(in: channelID)?.messages)
        // The clip, a teammate's view of the same moment, and two comments.
        let foot = Array(messages.suffix(4))
        let attachment = try #require(foot.first?.attachments.first)
        let clip = try #require(attachment.clip)
        #expect(attachment.contentType == "video/mp4")
        #expect(clip.participants.count == 5, "four faces and one more")
        #expect(clip.hasSpeaking && clip.hasTimelineComments)
        #expect(clip.applicationName == "Battlefield 6")
        let kills = clip.timeline.compactMap { entry -> Double? in
            guard case .game(let type, _) = entry.event, type == .kill || type == .multikill else { return nil }
            return Double(entry.timestampMS) / 1_000
        }
        #expect(kills == DemoMedia.gameClipKills, "the marks fall on the picture's flashes")

        for reply in foot.dropFirst() {
            #expect(reply.referencedMessageID == foot.first?.id)
        }
        // Phase 7.3: the second view shares the moment's id, so the player
        // offers it.
        let view = try #require(foot[1].attachments.first?.clip)
        #expect(view.remoteID == clip.remoteID && clip.remoteID != nil)
        #expect(ClipPointsOfView.views(of: attachment, in: messages).count == 2)
        for comment in foot.dropFirst(2) {
            #expect(comment.mediaMention?.attachmentID == attachment.id)
        }
        let comments = model.timelineComments(on: attachment.id, in: channelID)
        #expect(comments.map(\.content) == ["that flank was insane", "😆"])
        #expect(comments.last?.emoji == .unicode("😆"))
    }

    @Test("Settings › Experiments has the account's, the open server's and the newer ones")
    func experiments() throws {
        let model = self.model()
        #expect(model.experiments.user.count == 6)
        // Native markdown, search feedback, badge settings (Phase 8), and
        // Server Theme's account half, which the Boost goal counts.
        #expect(model.experiments.apex.count == 4)
        #expect(model.badgeManagement == (enabled: true, tenureHideable: true))
        let open = try #require(model.selectedGuildID)
        // The opening server is a community: in Server Theme in full.
        #expect(model.guildExperimentBucket("2026-04_server_theme", in: open) == 1)
        #expect(model.guildExperimentBucket("2026-02_hangout_window", in: open) == ExperimentBucket.control)
        #expect(model.guildExperimentBucket(AppModel.voiceChannelRowExperiment, in: open) == nil)
    }
}
