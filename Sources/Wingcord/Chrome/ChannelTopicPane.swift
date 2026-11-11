import SwiftUI
import WingcordCore

/// What a channel is for, in the words whoever set it up wrote — the body of
/// `ChannelTopicSheet` (Channel › Show Details, and the title menu's first
/// item), which supplies the ground and the padding.
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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                Image(symbol: symbolName)
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
                // The card opens on the emoji, from the prose: an anchor of
                // nothing put it in the window's corner.
                inspectsEmoji: true,
                onLink: openLink
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
