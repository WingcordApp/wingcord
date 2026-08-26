import SwiftUI
import WingcordCore

/// The detail column.
///
/// **One type, always.** Its body branches internally on the presentation value;
/// its *identity* never changes. macOS re-resolves split-view column widths on a
/// structural detail swap and repeatedly steals width from the sidebar until the
/// rail slides underneath — and internal `_ConditionalContent` under a stable
/// outer type is not a structural swap, which is the precise property everything
/// here depends on.
///
/// Anything added later — a forum, a search panel, a voice stage — arrives as a
/// case on `WorkspacePresentation`, never as a branch in the split view's
/// builder.
struct WorkspacePane: View {
    var presentation: WorkspacePresentation

    var body: some View {
        HStack(spacing: 0) {
            PrimaryPane(content: presentation.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let supplementary = presentation.supplementary {
                SupplementaryPane(content: supplementary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The reading surface is opaque, and only the reading surface.
        //
        // A translucent transcript is legible over a terminal and unreadable
        // over a photograph — the desktop reads straight through the message
        // text. The bleed belongs to the CHROME: the sidebar column is vibrant
        // and this is not.
        .readingSurface()
    }
}

private struct PrimaryPane: View {
    var content: WorkspacePresentation.Primary

    var body: some View {
        switch content {
        case .empty:
            EmptyWorkspace()
        case .conversation(let channelID):
            ConversationPane(channelID: channelID)
        case .forum(let channelID):
            PlaceholderPane(
                symbol: "list.bullet.rectangle",
                title: "Forum",
                detail: "Forum channels are not built yet.",
                channelID: channelID
            )
        case .voice(let channelID):
            PlaceholderPane(
                symbol: "speaker.wave.2.fill",
                title: "Voice",
                detail: "Voice channels are not built yet.",
                channelID: channelID
            )
        }
    }
}

private struct SupplementaryPane: View {
    var content: WorkspacePresentation.Supplementary

    var body: some View {
        switch content {
        case .members:
            MemberListContainer()
                .frame(width: Proportions.memberColumnIdeal)
        case .thread(let channelID):
            PlaceholderPane(
                symbol: "text.bubble",
                title: "Thread",
                detail: "Threads are not built yet.",
                channelID: channelID
            )
            .frame(width: Proportions.memberColumnIdeal)
        case .search:
            PlaceholderPane(
                symbol: "magnifyingglass",
                title: "Search",
                detail: "Search is not built yet.",
                channelID: nil
            )
            .frame(width: Proportions.memberColumnIdeal)
        }
    }
}

/// No channel open.
struct EmptyWorkspace: View {
    var body: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text("No channel selected")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Text("Pick a server, then a channel.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A surface that exists in the navigation model but is not built yet.
///
/// It is a real case rather than a `fatalError` or an empty view, because the
/// presentation enum is what holds the detail column's type stable — a case that
/// cannot be rendered is a case that will be worked around with a branch in the
/// builder, which is the thing that must not happen.
struct PlaceholderPane: View {
    var symbol: String
    var title: String
    var detail: String
    var channelID: ChannelID?

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.secondary)
            Text(detail)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
