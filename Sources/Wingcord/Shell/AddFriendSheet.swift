import SwiftUI

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
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var tag = ""
    @State private var outcome: Result<String, FriendRequestFailure>?
    @State private var isSending = false

    private var canSend: Bool {
        !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: "Add Friend",
                subtitle: Text("You can add friends with their Discord username."),
                close: { AddFriendRequest.shared.isShown = false }
            )
            VStack(alignment: .leading, spacing: Spacing.snug) {
                GlassEffectContainer(spacing: Spacing.base) {
                    HStack(spacing: Spacing.base) {
                        ModalTextField(placeholder: "Username", text: $tag, symbolName: "at", onSubmit: send)
                        ModalButton(
                            title: "Send Request",
                            symbolName: "person.badge.plus",
                            role: .act,
                            isWorking: isSending,
                            action: send
                        )
                        .disabled(!canSend)
                    }
                }
                if let outcome {
                    Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(outcome.isSuccess ? Color(hex: 0x23A55A) : Color(hex: 0xF23F43))
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Spacing.group)
            .padding(.bottom, Spacing.group)
        }
        .frame(width: 460)
        .animation(motion.standard, value: outcome?.message)
        // A new name is a new question: the last answer goes.
        .onChange(of: tag) { _, _ in outcome = nil }
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        Task {
            outcome = await model.sessionController.sendFriendRequest(to: tag)
            isSending = false
            if outcome?.isSuccess == true { tag = "" }
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
