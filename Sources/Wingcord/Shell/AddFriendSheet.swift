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
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base * 1.5) {
            Text("Add Friend")
                .font(.title3.weight(.semibold))
            Text("You can add friends with their Discord username.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
            HStack(spacing: Spacing.base) {
                TextField("Username", text: $tag)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(send)
                Button("Send Friend Request", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
            if let outcome {
                Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(outcome.isSuccess ? Color(hex: 0x23A55A) : Color(hex: 0xF23F43))
                    .transition(.opacity)
            }
            HStack {
                Spacer()
                Button("Done") { AddFriendRequest.shared.isShown = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .animation(motion.standard, value: outcome?.message)
        // A new name is a new question: the last answer goes.
        .onChange(of: tag) { _, _ in outcome = nil }
        .onAppear { isFocused = true }
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
