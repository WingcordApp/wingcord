import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Discord's consent rules for voices in clips, and its call warning
/// (docs/CLIPS-PRESENCE.md, Phase 3 — web build 641803's `ClipsManager`).
@MainActor
@Suite("Clips consent", .serialized)
struct ClipConsentTests {

    private let me = UserID(rawValue: 1)
    private let sam = UserID(rawValue: 2)
    private let kai = UserID(rawValue: 3)
    private let elsewhere = UserID(rawValue: 4)
    private let guildID = GuildID(rawValue: 10)
    private let lounge = ChannelID(rawValue: 20)
    private let stage = ChannelID(rawValue: 21)

    /// A model in a call in `channel`, with Sam and Kai in it and somebody in
    /// another room, clips on for the length of the test.
    private func model(in channel: ChannelID) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.channelIndex.upsert(Channel(id: lounge, kind: .voice, guildID: guildID, name: "Lounge"))
        model.channelIndex.upsert(Channel(id: stage, kind: .stage, guildID: guildID, name: "Stage"))
        for userID in [me, sam, kai] {
            model.voiceStates[userID] = VoiceState(userID: userID, channelID: channel, guildID: guildID)
        }
        model.voiceStates[elsewhere] = VoiceState(userID: elsewhere, channelID: ChannelID(rawValue: 99), guildID: guildID)
        model.connectedVoiceChannelID = channel
        return model
    }

    private func withClipsOn(_ body: () throws -> Void) async rethrows {
        try await withAppSettings(\.clipsEnabled, \.clipLength) { settings in
            settings.clipsEnabled = true
            settings.clipLength = .oneMinute
            try body()
        }
    }

    @Test("Somebody else's voice is kept only when their flags allow it; never anybody's in a stage")
    func plan() async {
        await withClipsOn {
            let model = model(in: lounge)
            model.noteVoiceClientFlags([.allowsVoiceRecording], for: sam)
            model.noteVoiceClientFlags([.clipsEnabled], for: kai)
            model.noteVoiceClientFlags([.allowsVoiceRecording], for: elsewhere)
            model.noteVoiceClientFlags([.allowsVoiceRecording, .clipsEnabled], for: me)
            let plan = model.clipRecorder.callTap.plan
            #expect(plan.voices == [sam.rawValue])
            #expect(plan.keepsMicrophone)
            #expect(plan.keepsSoundboard)
            #expect(plan.window == 63)

            let onStage = self.model(in: stage)
            onStage.noteVoiceClientFlags([.allowsVoiceRecording], for: sam)
            #expect(onStage.clipRecorder.callTap.plan.voices.isEmpty)
            #expect(!onStage.clipRecorder.callTap.plan.keepsMicrophone)
        }
    }

    @Test("Clips off keeps nothing from the call")
    func clipsOff() async {
        await withAppSettings(\.clipsEnabled) { settings in
            settings.clipsEnabled = false
            let model = model(in: lounge)
            model.noteVoiceClientFlags([.allowsVoiceRecording], for: sam)
            #expect(model.clipRecorder.callTap.plan == .nothing)
        }
    }

    @Test("Somebody with clips on is said once per channel, and only while the reader allows recording")
    func warning() {
        let model = model(in: lounge)
        model.noteVoiceClientFlags([.clipsEnabled, .allowsVoiceRecording], for: sam)
        #expect(model.actionNotice?.text == AppModel.clipsCallWarning)
        #expect(model.actionNotice?.kind == .clips)
        let first = model.actionNotice?.id

        // A second person with clips on, same channel: no second notice.
        model.noteVoiceClientFlags([.clipsEnabled], for: kai)
        #expect(model.actionNotice?.id == first)

        // A new room is a new channel — its own notice.
        model.connectedVoiceChannelID = stage
        model.forgetVoiceClientFlags()
        model.noteVoiceClientFlags([.clipsEnabled], for: kai)
        #expect(model.actionNotice?.id != first)

        // The reader's own flags never warn them about themselves, and a
        // reader who does not allow recording is not being recorded.
        let quiet = self.model(in: lounge)
        quiet.noteVoiceClientFlags([.clipsEnabled], for: me)
        #expect(quiet.actionNotice == nil)
        quiet.syncedPreferences.allowsVoiceRecordingInClips = false
        quiet.noteVoiceClientFlags([.clipsEnabled], for: sam)
        #expect(quiet.actionNotice == nil)
    }

    @Test("What Wingcord announces is Discord's computeVoiceFlags")
    func announced() async {
        await withAppSettings(\.clipsEnabled) { settings in
            let model = AppModel()
            settings.clipsEnabled = false
            #expect(model.announcedVoiceFlags == [.allowsVoiceRecording])
            settings.clipsEnabled = true
            #expect(model.announcedVoiceFlags == [.allowsVoiceRecording, .clipsEnabled])
            model.syncedPreferences.allowsVoiceRecordingInClips = false
            #expect(model.announcedVoiceFlags == [.clipsEnabled])
        }
    }
}
