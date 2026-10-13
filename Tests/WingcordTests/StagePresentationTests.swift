import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// The stage as a moderator sees it: Discord's queue, its "Invite Sent", and
/// "Allow requests from @everyone" read from the channel's own overwrite.
@MainActor
@Suite("Stage presentation")
struct StagePresentationTests {
    private let guildID = GuildID(rawValue: 1)
    private let channelID = ChannelID(rawValue: 10)
    private let reader = UserID(rawValue: 7)

    private func model(everyone overwrite: PermissionOverwrite? = nil) -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        // The owner holds every permission, so the reader moderates.
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: reader)
        var channel = Channel(id: channelID, kind: .stage, guildID: guildID, name: "Town Hall")
        if let overwrite { channel.overwrites = [overwrite] }
        model.channelIndex.replaceChannels([channel], inGuild: guildID)
        model.voiceStates[reader] = VoiceState(userID: reader, channelID: channelID, guildID: guildID)
        let asked = UserID(rawValue: 20), invited = UserID(rawValue: 21)
        model.voiceStates[asked] = VoiceState(
            userID: asked, channelID: channelID, guildID: guildID,
            isSuppressed: true, requestToSpeakAt: Date(timeIntervalSince1970: 5)
        )
        model.voiceStates[invited] = VoiceState(
            userID: invited, channelID: channelID, guildID: guildID,
            isSuppressed: false, requestToSpeakAt: Date(timeIntervalSince1970: 6)
        )
        return model
    }

    @Test("Hands in order, the answered one as Invite Sent, each labelled")
    func requests() throws {
        let stage = try #require(model().stagePresentation(of: channelID))
        #expect(stage.isModerator)
        #expect(stage.requests.map(\.id.rawValue) == [20, 21])
        #expect(stage.requests.map(\.isInvited) == [false, true])
        #expect(stage.requests.allSatisfy { $0.requestLabel != nil })
        // The invited person is not on the stage until they accept.
        #expect(stage.speakers.map(\.id) == [reader])
    }

    /// `stageInstances` was `@ObservationIgnored` by accident — an attribute
    /// stranded above its doc comment when properties were inserted between
    /// it and the memo cache it belonged to — so a stage going live redrew
    /// nothing that was not also moved by a voice state.
    @Test("A stage going live re-evaluates whoever reads it")
    func liveIsObserved() {
        let model = model()
        let heard = Heard()
        withObservationTracking {
            _ = model.stagePresentation(of: channelID)?.isLive
        } onChange: {
            heard.value = true
        }
        model.stageInstances[channelID] = StageInstance(
            id: 1, guildID: guildID, channelID: channelID, topic: "Q&A"
        )
        #expect(heard.value)
    }

    /// Discord's `isOnStartStageScreen`: a moderator's, until Continue without
    /// starting or the stage going live puts it away for as long as they stay.
    @Test("The start screen is a moderator's until they continue, and comes back after they leave")
    func startScreen() {
        let model = model()
        #expect(model.stagePresentation(of: channelID)?.showsStartScreen == true)
        model.connectedVoiceChannelID = channelID
        model.continueStageWithoutStarting(inChannel: channelID)
        #expect(model.stagePresentation(of: channelID)?.showsStartScreen == false)
        model.applyStage(StageInstance(id: 1, guildID: guildID, channelID: channelID, topic: "Q&A"))
        model.applyStageEnded(channelID)
        #expect(model.stagePresentation(of: channelID)?.showsStartScreen == false)
        model.connectedVoiceChannelID = nil
        #expect(model.stagePresentation(of: channelID)?.showsStartScreen == true)
    }

    /// Discord's renderer: the line wears Invite to Speak only while its
    /// author's hand is the one it announced, to the millisecond, and only
    /// while they are still asking — not once invited.
    @Test("Invite to Speak under a request is offered while that hand is up")
    func openRequests() {
        let model = model()
        let asked = UserID(rawValue: 20), invited = UserID(rawValue: 21)
        func line(_ author: UserID, at seconds: Double) -> Message {
            let milliseconds = UInt64(seconds * 1000) - 1_420_070_400_000
            return Message(
                id: MessageID(rawValue: milliseconds << 22),
                channelID: channelID,
                authorID: author,
                kind: .stageRaiseHand
            )
        }
        let raised = Date(timeIntervalSince1970: 1_800_000_000.25)
        model.voiceStates[asked]?.requestToSpeakAt = raised
        model.voiceStates[invited]?.requestToSpeakAt = raised
        var box = MessageBox()
        box.messages = [
            line(asked, at: 1_800_000_000.25),
            line(asked, at: 1_799_999_000),
            line(invited, at: 1_800_000_000.25),
        ]
        model.setMessages(box, in: channelID)
        #expect(model.openStageRequests(in: channelID) == [box.messages[0].id])
    }

    @Test("The waiting music plays while nobody speaks, and stops for a deafen")
    func music() {
        let model = model()
        // An invitation still unanswered is unsuppressed, and Discord counts
        // it as a voice on the stage; this room is the reader's alone.
        model.voiceStates[UserID(rawValue: 21)] = nil
        model.connectedVoiceChannelID = channelID
        // The reader is on the stage with an open microphone.
        #expect(model.stageMusicPlayback == .paused)
        model.isSelfMuted = true
        #expect(model.stageMusicPlayback == .playing)
        model.isSelfDeafened = true
        #expect(model.stageMusicPlayback == .stopped)
        model.isSelfDeafened = false
        model.applyStage(StageInstance(id: 1, guildID: guildID, channelID: channelID, topic: "Q&A"))
        #expect(model.stageMusicPlayback == .stopped)
        model.stageMusicRequested = true
        #expect(model.stageMusicPlayback == .playing)
        // Discord forgets the request as the reader moves.
        model.connectedVoiceChannelID = nil
        #expect(!model.stageMusicRequested)
    }

    /// Discord's `106044`: alone among the moderators on the stage, the
    /// reader is asked whether it ends with them.
    @Test("The last moderator speaking is asked whether the stage ends")
    func lastModerator() {
        let model = model()
        #expect(!model.isLastStageModerator(in: channelID))
        model.stageInstances[channelID] = StageInstance(id: 1, guildID: guildID, channelID: channelID, topic: "Q&A")
        #expect(model.isLastStageModerator(in: channelID))
        model.voiceStates[reader]?.isSuppressed = true
        #expect(!model.isLastStageModerator(in: channelID))
    }

    @Test("Blocked and ignored people in the room are counted and listed")
    func flaggedPeople() throws {
        let model = model()
        model.blockedUserIDs = [UserID(rawValue: 20)]
        model.ignoredUserIDs = [UserID(rawValue: 21)]
        let stage = try #require(model.stagePresentation(of: channelID))
        #expect(stage.blockedCount == 1)
        #expect(stage.ignoredCount == 1)
        let people = model.stageFlaggedPeople(in: channelID)
        #expect(people.map(\.isBlocked) == [true, false])
        #expect(people.allSatisfy { $0.place == "Audience" })
    }

    @Test("Allow requests from @everyone reads the channel's @everyone overwrite")
    func everyone() {
        let allowed = PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [.requestToSpeak], deny: [])
        let denied = PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [], deny: [.requestToSpeak])
        #expect(model(everyone: allowed).stagePresentation(of: channelID)?.allowsEveryoneToRequest == true)
        #expect(model(everyone: denied).stagePresentation(of: channelID)?.allowsEveryoneToRequest == false)
    }
}

nonisolated private final class Heard: @unchecked Sendable {
    var value = false
}
