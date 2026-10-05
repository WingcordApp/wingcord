import SwiftUI
import WingcordCore
import WingcordNet

/// The voice channel whose status the reader is writing.
struct VoiceStatusRequest: Identifiable, Equatable {
    var channelID: ChannelID
    var id: ChannelID { channelID }
}

extension AppModel {
    /// Opens Discord's "What are we chatting about?" on a voice channel.
    func editVoiceStatus(in channelID: ChannelID) {
        voiceStatusEditor = VoiceStatusRequest(channelID: channelID)
    }

    /// Writes a voice channel's status, answering Discord's refusal in its own
    /// words — or nil once it is set. The status itself is redrawn by the
    /// gateway's echo, as it is for every other client.
    func saveVoiceStatus(_ status: String, in channelID: ChannelID) async -> String? {
        do {
            try await sessionController.rest.setVoiceChannelStatus(status, in: channelID)
            return nil
        } catch DiscordREST.Failure.api(_, _, let message?) {
            return message
        } catch {
            return "Something went wrong, try again later"
        }
    }

    /// Discord's Clear Channel Status — the same route with nothing in it.
    func clearVoiceStatus(in channelID: ChannelID) {
        Task { _ = await saveVoiceStatus("", in: channelID) }
    }
}

/// Discord's voice channel status modal (`136523`): its picture, "What are we
/// chatting about?", one line of status with its emoji, and Set Status.
///
/// **One line, 500 characters**, as Discord's input is — no new lines, and the
/// count of what is left shown once the status passes 250.
struct VoiceStatusSheet: View {
    var request: VoiceStatusRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var isFocused = true
    @State private var isSaving = false
    @State private var error: String?

    private static let limit = 500
    private static let countAfter = 250

    var body: some View {
        FormSheet(
            title: "What are we chatting about?",
            subtitle: Text("Let others know what you\u{2019}re up to in the voice channel!"),
            confirmTitle: "Set Status",
            isWorking: isSaving,
            canConfirm: text.count <= Self.limit,
            confirm: submit
        ) {
            if let art = VoiceStatusArt.image {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Status")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                MarkdownEditor(
                    text: $text,
                    isFocused: $isFocused,
                    placeholder: "Status for \(channelName)",
                    font: NSFont.preferredFont(forTextStyle: .body),
                    lines: 1...1,
                    characterLimit: Self.limit,
                    returnSubmits: true,
                    onSubmit: submit
                )
                .padding(Spacing.base)
                .background(Palette.hoverFill, in: .rect(cornerRadius: 8, style: .continuous))
                HStack {
                    if let error {
                        Text(error)
                            .font(.system(.caption))
                            .foregroundStyle(Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if text.count > Self.countAfter {
                        Text("\(Self.limit - text.count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Ink.tertiary)
                    }
                }
            }
        }
        .onAppear {
            original = model.voiceChannelInfo[request.channelID]?.status ?? ""
            text = original
        }
    }

    private var channelName: String {
        model.channelIndex[request.channelID].map(model.displayName(of:)) ?? ""
    }

    /// Discord sends nothing for an unchanged status, and closes.
    private func submit() {
        guard !isSaving, text.count <= Self.limit else { return }
        guard text != original else {
            dismiss()
            return
        }
        error = nil
        isSaving = true
        Task {
            let refusal = await model.saveVoiceStatus(text, in: request.channelID)
            isSaving = false
            if let refusal {
                error = refusal
            } else {
                dismiss()
            }
        }
    }
}

/// Discord's picture for the modal, read from the bundle once.
private enum VoiceStatusArt {
    @MainActor static let image: NSImage? = Bundle.module
        .url(forResource: "voice-status", withExtension: "svg", subdirectory: "Art")
        .flatMap(NSImage.init(contentsOf:))
}
