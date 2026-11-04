import SwiftUI
import WingcordCore

/// What somebody wrote with their request, under it: "View note", then the note and
/// "Hide note" — Discord's `e_` (`763349`).
///
/// **Covered until the reader asks.** It's words from a stranger, and Discord's
/// "View note" is a press it counts rather than a convenience. Nothing at all where
/// there's no note or the reader turned these off.
struct FriendRequestNoteLine: View {
    var userID: UserID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isShown = false

    var body: some View {
        Group {
            if let note = model.friendRequestNote(of: userID) {
                if isShown {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Ink.tertiary)
                            Text(note)
                                .font(.system(.caption))
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        link("Hide note") { isShown = false }
                    }
                    .transition(.opacity)
                } else {
                    Button { isShown = true } label: {
                        HStack(spacing: Spacing.tight) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("View note")
                                .font(.system(.caption, weight: .medium))
                        }
                        .foregroundStyle(Palette.accent)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
        }
        .animation(motion.standard, value: isShown)
        .task { await model.sessionController.loadMessagingPrivacy() }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Palette.accent)
    }
}

/// "{name} sent you a friend request", on their profile — Discord's `ep` (`931481`):
/// the note covered until "View Request" is pressed, then Accept and Ignore.
struct ProfileFriendRequestBlock: View {
    var userID: UserID
    var name: String

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            (Text(name).fontWeight(.semibold) + Text(" sent you a friend request."))
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.solid)
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.friendRequestNote(of: userID) {
                ZStack {
                    Text(note)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(InkColor.solid)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .blur(radius: isRevealed ? 0 : 7)
                        .accessibilityHidden(!isRevealed)
                    if !isRevealed {
                        Button("View Request", systemImage: "eye.fill") { isRevealed = true }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                }
                .animation(motion.standard, value: isRevealed)
            }
            HStack(spacing: Spacing.base) {
                Button("Accept") { model.answerFriendRequest(userID, accept: true) }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                Button("Ignore") { model.answerFriendRequest(userID, accept: false) }
                    .buttonStyle(.glass)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(model.relationshipsInFlight.contains(userID))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.sessionController.loadMessagingPrivacy() }
    }
}
