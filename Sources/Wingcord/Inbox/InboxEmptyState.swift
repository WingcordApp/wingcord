import SwiftUI
import WingcordCore

/// What a tab says when it has nothing in it.
///
/// **Each one names the act that would fill it**, because four of the five are
/// empty for a reason the reader can do something about — and a bare "Nothing
/// here" leaves somebody wondering whether the feature is broken. The Unreads
/// tab is the exception: being empty is the goal, so it is the only one that
/// congratulates rather than instructs.
///
/// **No illustration.** Discord draws Wumpus here; this app has no mascot and
/// borrowing one would be the one place its own vocabulary gave way. A symbol,
/// a line of type and a sentence is what every other empty surface in Wingcord
/// uses.
struct InboxEmptyState: View {
    var tab: InboxTab

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: symbolName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Ink.tertiary)
                .padding(.bottom, Spacing.tight)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
            Text(message)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbolName: String {
        switch tab {
        case .unreads: "checkmark.circle"
        case .mentions: "at"
        case .bookmarks: "bookmark"
        case .reminders: "bell"
        case .scheduled: "calendar.badge.clock"
        }
    }

    private var title: String {
        switch tab {
        case .unreads: "You're all caught up"
        case .mentions: "No mentions"
        case .bookmarks: "Nothing saved"
        case .reminders: "No reminders"
        case .scheduled: "Nothing queued"
        }
    }

    private var message: String {
        switch tab {
        case .unreads:
            "Nothing unread in any server or conversation."
        case .mentions:
            // **The window is Discord's and it is worth saying.** Mentions are
            // kept for seven days server-side, so an empty tab on an account
            // that was pinged last month is correct rather than broken — and
            // without this line it reads as a bug.
            "Nobody has mentioned you in the past seven days."
        case .bookmarks:
            "Right-click any message and pick Bookmark Message to keep it here."
        case .reminders:
            "Right-click any message and pick Create Reminder to be nudged about it."
        case .scheduled:
            "Messages you schedule to send later wait here until they go out."
        }
    }
}
