import SwiftUI
import WingcordCore

/// Whether Add Friend is up — asked for from the `+⌄` menu, which cannot host
/// a sheet of its own.
@Observable
@MainActor
final class AddFriendRequest {
    static let shared = AddFriendRequest()
    var isShown = false
}

/// Discord's Add Friend: a username, a request, and Discord's own sentence for
/// how it went (REDESIGN.md R12).
struct AddFriendSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: "Add Friend",
                subtitle: Text("You can add friends with their Discord username."),
                close: { AddFriendRequest.shared.isShown = false }
            )
            AddFriendForm()
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.group)
        }
        .frame(width: 460)
    }
}

/// A username, a note, and the request: the same form in the card the menu bar opens
/// and in the flyout on the member list's head (`eF`, `763349`).
struct AddFriendForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var tag = ""
    @State private var note = ""
    @State private var outcome: Result<String, FriendRequestFailure>?
    @State private var isSending = false
    @FocusState private var isNoteFocused: Bool

    private var canSend: Bool {
        !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            ModalTextField(placeholder: "Username", text: $tag, symbolName: "at", onSubmit: send)

            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack {
                    Text("Add a note (optional)")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                    Spacer(minLength: 0)
                    // Discord's `showCharacterCount`: the limit is typed against,
                    // not found out about.
                    Text("\(note.count)/\(FriendRequestNote.maximumLength)")
                        .font(.system(.caption).monospacedDigit())
                        .foregroundStyle(Ink.tertiary)
                }
                TextField("e.g. let\u{2019}s be friends yipee!", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                    .lineLimit(3, reservesSpace: true)
                    .focused($isNoteFocused)
                    .padding(.horizontal, Spacing.snug)
                    .padding(.vertical, Spacing.base)
                    .modalFieldGround(isFocused: isNoteFocused)
                    .onChange(of: note) { _, new in
                        if new.count > FriendRequestNote.maximumLength {
                            note = String(new.prefix(FriendRequestNote.maximumLength))
                        }
                    }
                Text("What you write here will also show up in your DM if you become friends.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ModalButton(
                title: "Send Friend Request",
                symbolName: "person.badge.plus",
                role: .act,
                isWorking: isSending,
                fills: true,
                // Return belongs to the note's own lines.
                shortcut: .some(nil),
                action: send
            )
            .disabled(!canSend)

            if let outcome {
                Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(outcome.isSuccess ? Color(hex: 0x23A55A) : Color(hex: 0xF23F43))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(motion.standard, value: outcome?.message)
        // A new name is a new question: the last answer goes.
        .onChange(of: tag) { _, _ in outcome = nil }
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        Task {
            outcome = await model.sessionController.sendFriendRequest(to: tag, note: note)
            isSending = false
            if outcome?.isSuccess == true {
                tag = ""
                note = ""
            }
        }
    }
}

private extension Result where Success == String, Failure == FriendRequestFailure {
    var message: String {
        switch self {
        case .success(let text): text
        case .failure(let failure): failure.message
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
