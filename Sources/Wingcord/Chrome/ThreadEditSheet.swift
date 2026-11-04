import SwiftUI
import WingcordCore
import WingcordNet

/// Edit Thread and Edit Post: Discord's settings for a thread — the Overview of
/// its channel settings, which is all a thread has (`13eee04b11ba2913`'s
/// `renderChannelInfo` for the thread kinds).
///
/// **Its fields, its words, and who may change each**: the name to its author
/// while they may send and otherwise to whoever moderates it; Slowmode to
/// Manage Threads; Hide After Inactivity, Anyone can invite on a private
/// thread, and Spoiler Channel to the author or a moderator — see
/// `ThreadGate`. A field the reader cannot change is shown and greyed out, as
/// Discord's are.
///
/// **One write, of what changed** — and a closed thread is opened first, as
/// Discord's save does.
struct ThreadEditSheet: View {
    var request: ThreadEditRequest

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var isSaving = false
    @State private var error: String?

    /// Discord's cap on a channel's name.
    private static let nameLimit = 100

    /// The fields, as the sheet holds them.
    struct Draft: Equatable {
        var name = ""
        var slowmode = 0
        var autoArchiveMinutes = 4320
        var isInvitable = true
        var isSpoiler = false
    }

    var body: some View {
        let menu = model.threadMenu(for: request.threadID)
        let gate = menu?.gate
        let isPost = menu?.isPost ?? false
        let isPrivate = model.channelIndex[request.threadID]?.kind == .privateThread

        FormSheet(
            title: isPost ? "Post Settings" : "Thread Settings",
            confirmTitle: "Save Changes",
            isWorking: isSaving,
            canConfirm: !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            confirm: save
        ) {
            SheetField(title: isPost ? "Post Title" : "Thread Name", isRequired: true) {
                TextField("", text: Binding(
                    get: { draft.name },
                    set: { draft.name = String($0.prefix(Self.nameLimit)) }
                ))
                .modalField()
                .disabled(gate?.canRename != true)
                .accessibilityLabel(Text(isPost ? "Post Title" : "Thread Name"))
            }

            SheetField(
                title: "Slowmode",
                detail: "Members will be restricted to sending one message per this interval, unless "
                    + "they have the Bypass Slowmode permission."
            ) {
                FlyoutPicker(
                    selection: $draft.slowmode,
                    options: SlowmodeChoices.choices(including: draft.slowmode),
                    title: SlowmodeChoices.title,
                    accessibilityTitle: "Slowmode",
                    isEnabled: gate?.canSetSlowmode == true
                )
            }

            SheetField(
                title: "Hide After Inactivity",
                detail: isPost
                    ? "Posts will not show in the channel list after being inactive for the specified duration."
                    : "Threads will not show in the channel list after being inactive for the specified duration."
            ) {
                FlyoutPicker(
                    selection: $draft.autoArchiveMinutes,
                    options: ThreadArchiveDuration.minutes,
                    title: ThreadArchiveDuration.title,
                    accessibilityTitle: "Hide After Inactivity",
                    isEnabled: gate?.canChangeSettings == true
                )
            }

            if isPrivate {
                toggle(
                    "Anyone can invite",
                    detail: "When disabled, only moderators and the thread creator can add new members to this thread.",
                    isOn: $draft.isInvitable,
                    isEnabled: gate?.canChangeSettings == true
                )
            }

            toggle(
                "Spoiler Channel",
                detail: "Mark this channel as containing spoilers, so that plot twists, heavy topics, or other "
                    + "sensitive discussions are hidden until users choose to view.",
                isOn: $draft.isSpoiler,
                isEnabled: gate?.canChangeSettings == true
            )

            if let error {
                Text(error)
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>, isEnabled: Bool) -> some View {
        SheetField(title: title, detail: detail) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }

    private func load() {
        guard let thread = model.channelIndex[request.threadID] else { return }
        let loaded = Draft(
            name: thread.name,
            slowmode: thread.rateLimitPerUser,
            autoArchiveMinutes: thread.threadMetadata?.autoArchiveMinutes ?? 4320,
            isInvitable: thread.threadMetadata?.isInvitable ?? true,
            isSpoiler: thread.flags.contains(.spoilerChannel)
        )
        original = loaded
        draft = loaded
    }

    /// Sends what changed, and closes — or keeps the sheet up with Discord's
    /// words for the refusal.
    private func save() {
        guard !isSaving, let thread = model.channelIndex[request.threadID] else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var edit = ThreadEdit()
        if name != original.name { edit.name = name }
        if draft.slowmode != original.slowmode { edit.rateLimitPerUser = draft.slowmode }
        if draft.autoArchiveMinutes != original.autoArchiveMinutes {
            edit.autoArchiveMinutes = draft.autoArchiveMinutes
        }
        if draft.isInvitable != original.isInvitable { edit.invitable = draft.isInvitable }
        if draft.isSpoiler != original.isSpoiler {
            // The whole bitfield, the bits this client cannot draw included.
            var flags = thread.flags
            if draft.isSpoiler { flags.insert(.spoilerChannel) } else { flags.remove(.spoilerChannel) }
            edit.flags = flags
        }
        guard !edit.isEmpty else {
            dismiss()
            return
        }
        error = nil
        isSaving = true
        Task {
            let refusal = await model.saveThreadEdit(edit, to: request.threadID)
            isSaving = false
            if let refusal {
                error = refusal
            } else {
                dismiss()
            }
        }
    }
}
