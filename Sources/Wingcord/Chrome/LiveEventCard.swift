import SwiftUI
import WingcordCore

/// The card at the head of a server's channels while one of its events is on —
/// Discord's live channel notice (`263294`): "Happening Now" with the place and
/// Event Details for an event somewhere else, "Live Now" with the room and a
/// way in for one in a voice or stage channel.
///
/// **Clear glass, untinted**, because it floats in the sidebar column, which
/// paints nothing: what passes under it is the reader's own desktop and the
/// channel list, and a frosted card there is the slab §4 forbids. Closing it
/// lasts the session, as Discord's does.
struct LiveEventCard: View {
    var notice: LiveEventNotice
    var open: () -> Void
    /// Nil for an event that is not in a room the reader may join.
    var join: (() -> Void)?
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.presenceOnline)
                    .frame(width: 7, height: 7)
                Text(notice.heading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.presenceOnline)
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.tertiary)
                .help("Close")
                .accessibilityLabel(Text("Close"))
            }

            // The name opens the event, as Discord's upcoming notice does.
            Button(action: open) {
                Text(notice.name)
                    .font(.headline)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(symbol: notice.placeSymbol)
                    .font(.caption)
                    .foregroundStyle(Ink.tertiary)
                // Markdown, as Discord parses a location: a link in it is a
                // link, and a link to a channel is the channel's chip — "🔒 No
                // Access" for one the reader cannot see.
                ProseText(
                    markdown: notice.place,
                    font: .caption,
                    color: InkColor.secondary,
                    mentions: model.mentionContext(),
                    onLink: { model.openLink($0) }
                )
                .lineLimit(2)
            }

            Button(action: join ?? open) {
                Text(join == nil ? "Event Details" : notice.joinTitle)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.presenceOnline)
            .padding(.top, 2)
        }
        .padding(Spacing.snug)
        // A card in the list, so a solid one: content, not glass.
        .sidebarCard(cornerRadius: Radius.glass)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(notice.heading): \(notice.name)"))
    }
}
