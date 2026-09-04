import SwiftUI
import WingcordCore

/// What a channel is for, in the words whoever set it up wrote.
///
/// **A popover off the toolbar's own pill** — the one place in this app a
/// presentation may be attached inline, and for the reasons `ChannelToolbar`
/// gives: it is one item, evaluated once, and it is the only way to point a
/// surface at the control that opened it.
///
/// **Markdown, not a plain string.** A topic is a field people write emoji,
/// custom emoji, links and `**bold**` into by hand — Discord renders all of it —
/// and a `Text` shows `<:sakura:123>` as literal angle brackets. `ProseText` is
/// the same tree the transcript draws, rendered in SwiftUI.
struct ChannelTopicPane: View {
    var name: String
    var symbolName: String
    var topic: String
    /// Resolves mentions inside the topic. A channel description very often
    /// names another channel.
    var mentions: MentionContext
    var openLink: (String) -> Void
    var openEmoji: (EmojiRef) -> Void

    private static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.tertiary)
                Text(name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
            }

            ProseText(
                markdown: topic,
                font: .system(.subheadline),
                color: InkColor.secondary,
                emojiSide: 18,
                mentions: mentions,
                onEmoji: openEmoji,
                onLink: openLink
            )
        }
        .padding(Spacing.snug)
        .frame(width: Self.width, alignment: .leading)
        // The popover supplies the material; this must not add a second.
        .presentationBackground(.clear)
    }
}
