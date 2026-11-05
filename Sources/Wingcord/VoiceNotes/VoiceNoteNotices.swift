import AppKit
import SwiftUI
import WingcordCore

/// The cards a voice message can raise: the microphone's refused or silent, the recording
/// failed, or a note's already waiting somewhere else.
struct VoiceNoteNotices: ViewModifier {
    var model: AppModel

    private var notice: VoiceNoteRecorder.Notice? { model.voiceRecorder.notice }

    func body(content: Content) -> some View {
        content.modal(
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { model.voiceRecorder.notice = nil } }
            ),
            style: .alert
        ) {
            if let notice {
                card(for: notice)
            }
        }
    }

    @ViewBuilder
    private func card(for notice: VoiceNoteRecorder.Notice) -> some View {
        switch notice {
        case .microphoneRefused:
            ModalAlert(
                hero: .symbol("mic.slash.fill"),
                title: "Wingcord can't use your microphone",
                message: Text("Turn on microphone access for Wingcord in System Settings to record voice messages."),
                actions: [
                    .cancel(),
                    .act("Open System Settings", symbol: "gear") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    },
                ]
            )
        case .microphoneSilent:
            ModalAlert(
                hero: .symbol("mic.slash.fill"),
                title: "Your microphone isn't sending anything",
                message: Text("Nothing was recorded. Check which input is chosen in Voice & Video settings, then try again."),
                actions: [.okay("OK")]
            )
        case .recordingFailed:
            ModalAlert(
                hero: .symbol("exclamationmark.triangle.fill", tint: .orange),
                title: "That recording couldn't be saved",
                message: Text("Something went wrong writing it to this Mac. Try recording it again."),
                actions: [.okay("OK")]
            )
        case .heldElsewhere(let other, let wanted):
            ModalAlert(
                hero: .symbol("mic.fill"),
                title: "You have an unsent voice message",
                message: Text("It's waiting in \(placeName(other)). Go back to it, or discard it and record a new one."),
                actions: [
                    .cancel("Go Back") {
                        // Across servers, as the note may be.
                        model.selectGuild(model.channelIndex.guildID(of: other))
                        model.selectChannel(other)
                    },
                    .act("Discard", symbol: "trash", irreversible: true) {
                        model.discardVoiceNote()
                        model.startVoiceNote(in: wanted)
                    },
                ]
            )
        }
    }

    private func placeName(_ channelID: ChannelID) -> String {
        guard let channel = model.channelIndex[channelID] else { return "another conversation" }
        let name = model.displayName(of: channel)
        return channel.kind.isPrivate ? name : "#\(name)"
    }
}
