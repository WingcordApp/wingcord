import SwiftUI
import WingcordCore

// MARK: - The moderation dialogs' chrome
//
// Discord's moderation modals share one frame — a title, a line under it, the
// form, then Cancel and the act — and it is the window's `FormSheet`, which
// every other form sheet wears too.

/// One moderation dialog, chosen by its request.
struct ModerationDialogView: View {
    var dialog: ModerationDialog

    @Environment(AppModel.self) private var model

    var body: some View {
        switch dialog {
        case .kick(let user, let guild):
            KickDialog(userID: user, guildID: guild)
        case .ban(let user, let guild):
            BanDialog(targets: .one(user), guildID: guild)
        case .bulkBan(let users, let guild):
            BanDialog(targets: .many(users), guildID: guild)
        case .timeout(let user, let guild):
            TimeoutDialog(userID: user, guildID: guild)
        case .removeTimeout(let user, let guild):
            RemoveTimeoutDialog(userID: user, guildID: guild)
        case .nickname(let user, let guild):
            NicknameDialog(
                userID: user,
                guildID: guild,
                current: model.members[guild]?[user]?.nickname
            )
        case .prune(let guild):
            PruneDialog(guildID: guild)
        }
    }
}

/// The frame every moderation dialog wears: the window's `FormSheet`,
/// confirmed with ⌘Return because a reason is a text area that wants Return
/// for its own line breaks.
struct ModerationSheet<Content: View>: View {
    var title: String
    var subtitle: Text?
    var confirmTitle: String
    /// Discord's `critical-primary` — Kick, Ban, Remove Timeout.
    var isDestructive: Bool
    /// A write in flight: the button spins and nothing can be pressed twice.
    var isWorking = false
    var confirm: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        FormSheet(
            title: title,
            subtitle: subtitle,
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            isWorking: isWorking,
            confirmShortcut: KeyboardShortcut(.return, modifiers: .command),
            confirm: confirm
        ) {
            content
        }
    }
}

/// A moderation reason: Discord's text area, held to its 512 characters.
struct ReasonField: View {
    var placeholder = ""
    @Binding var text: String
    /// The rows Discord's area opens with — two for a kick, four for a
    /// timeout, five for a ban's Other.
    var lines: Int

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.body))
            .lineLimit(lines...max(lines, 8))
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
            .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Palette.edge) }
            .onChange(of: text) { _, reason in
                if reason.count > ModerationReason.maximumLength {
                    text = String(reason.prefix(ModerationReason.maximumLength))
                }
            }
    }
}
