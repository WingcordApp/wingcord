import AppKit
import SwiftUI
import WingcordCore

/// One announcement on a game's profile — Discord's card (`nX`, `nz`, `nK`
/// and `card_-weL8h`), in the app's own surface.
///
/// **The words are rendered, not reduced**: the title and the body go through
/// `ProseText`, so bold, links, mentions and emoji read as the post wrote them.
/// A press on plain words opens the post; a link answers for itself — the event
/// card's arrangement, and Discord's (`onCardClick` skips anchors).
struct GameAnnouncementCardView: View {
    var announcement: GameAnnouncementCard
    var mentions: MentionContext?
    var open: (() -> Void)?
    var openLink: ((String) -> Void)?

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let padding: CGFloat = 12
    private static let gap: CGFloat = 8
    private static let shape = RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
    private static let pictureShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
                // Discord's lift: the card holds still and what is in it rises
                // four points under the pointer.
                .offset(y: isHovering && !motion.reduceMotion ? -4 : 0)
        }
        .background(.thinMaterial, in: Self.shape)
        .overlay { Self.shape.strokeBorder(isHovering ? Palette.edgeStrong : Palette.edge) }
        .clipShape(Self.shape)
        .contentShape(Self.shape)
        .onTapGesture { open?() }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(announcement.spokenText))
        .accessibilityValue(Text(announcement.postedAt, format: .dateTime.month(.wide).day().year()))
        .accessibilityAddTraits(open == nil ? [] : .isButton)
        .accessibilityAction { open?() }
    }

    // MARK: The parts

    private func content(width: CGFloat) -> some View {
        let inner = max(0, width - Self.padding * 2)
        return VStack(alignment: .leading, spacing: Self.gap) {
            sourceLine
            main(inner: inner)
            Spacer(minLength: 0)
            footer
        }
        .padding(Self.padding)
        .frame(width: width, height: GameAnnouncementsShelf.cardHeight, alignment: .topLeading)
    }

    /// The link a post's words came from, over its card — Discord's
    /// `embedSourceUrl`, in link ink.
    @ViewBuilder
    private var sourceLine: some View {
        if let url = announcement.source?.url {
            Text(url)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Color(nsColor: .linkColor))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func main(inner: CGFloat) -> some View {
        if let poll = announcement.poll {
            pollBody(poll)
        } else if let source = announcement.source {
            // The embed's own colour down its edge, as Discord draws a link's
            // card.
            HStack(alignment: .top, spacing: Self.gap) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(source.colorValue.map { Color(hex: $0) } ?? Palette.edgeStrong)
                    .frame(width: 4)
                post(inner: inner - 12)
            }
        } else {
            post(inner: inner)
        }
    }

    private func post(inner: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            if let name = announcement.source?.authorName {
                authorRow(name, icon: announcement.source?.authorIconURL)
            }
            if let media = announcement.media {
                picture(media, width: inner)
            }
            words(width: inner)
        }
    }

    private func picture(_ media: GameAnnouncementCard.Media, width: CGFloat) -> some View {
        Color.clear
            .frame(width: max(0, width), height: max(0, width * 9 / 16))
            .background(Palette.surfaceRaised)
            .overlay {
                RemoteImage(
                    url: media.url,
                    side: CGFloat(AppModel.announcementPictureWidth) / 2,
                    bucket: .artwork,
                    arrival: motion.fadeQuick
                ) { Color.clear }
                .aspectRatio(contentMode: .fill)
            }
            .clipShape(Self.pictureShape)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func words(width: CGFloat) -> some View {
        if let title = announcement.title {
            ProseText(
                markdown: title,
                font: .system(.title3, weight: .semibold),
                color: InkColor.primary,
                emojiSide: 18,
                mentions: mentions,
                onLink: openLink,
                weight: .semibold,
                isSelectable: false
            )
            .lineLimit(1)
        }
        if !announcement.body.isEmpty {
            ProseText(
                markdown: announcement.body,
                font: .system(.body),
                color: InkColor.secondary,
                emojiSide: 16,
                mentions: mentions,
                onLink: openLink,
                isSelectable: false
            )
            .lineLimit(bodyLines(width: width))
        }
    }

    /// How many lines of the body fit in what the card has left.
    ///
    /// **Counted, not clipped**: the prose is an AppKit view and ends its last
    /// line with an ellipsis when it is told how many it has, which reads as a
    /// post that goes on; a clip would cut a line through its middle.
    private func bodyLines(width: CGFloat) -> Int {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let line = ceil(body.ascender - body.descender + body.leading) + 1
        let title = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold)
        var room = GameAnnouncementsShelf.cardHeight - Self.padding * 2
        room -= 18 + Self.gap // the footer, and the gap over it
        if announcement.media != nil {
            room -= width * 9 / 16 + Self.gap
        }
        if announcement.title != nil { room -= ceil(title.ascender - title.descender) + Self.gap }
        if announcement.source?.url != nil { room -= 16 + Self.gap }
        if announcement.source?.authorName != nil { room -= 20 + Self.gap }
        return max(1, Int(room / line))
    }

    private func authorRow(_ name: String, icon: URL?) -> some View {
        HStack(spacing: 6) {
            if let icon {
                RemoteImage(url: icon, side: 20, bucket: .thumbnail) { Color.clear }
                    .frame(width: 20, height: 20)
                    .clipShape(.circle)
            }
            Text(name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
    }

    /// A poll's card: its question, three answers in their own wells, how many
    /// more there are.
    private func pollBody(_ poll: GameAnnouncementCard.PollDigest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(poll.question)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(2)
            ForEach(Array(poll.answers.enumerated()), id: \.offset) { _, answer in
                Text(answer)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.hoverFill, in: Self.pictureShape)
            }
            if poll.more > 0 {
                Text(poll.more == 1 ? "+1 more option" : "+\(poll.more) more options")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Self.gap) {
            Text(announcement.postedAt, format: .dateTime.month(.wide).day().year())
            if announcement.reactionCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "face.smiling")
                    Text(announcement.reactionCount, format: .number)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(InkColor.secondary)
        .frame(height: 18)
    }
}
