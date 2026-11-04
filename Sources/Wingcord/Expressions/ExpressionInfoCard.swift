import SwiftUI
import WingcordCore

/// What an emoji or a sticker in a transcript actually is.
///
/// **Two regions, and the split is by question.** The top answers "what is
/// this" — the picture at a size worth looking at, its name, and one sentence.
/// The bottom answers "where is it from", and it is a *destination* rather than
/// a statement whenever the reader is in that server, which is why it is the
/// only part of the card that is a control.
///
/// A card with nothing to say about its source shows no footer at all rather
/// than a row saying "unknown". An empty region is the same picture whether the
/// answer is missing or does not exist, and the reader cannot tell which.
struct ExpressionInfoCard: View {
    var info: ExpressionInfo
    var openGuild: (GuildID) -> Void
    /// Opens the composer's sticker picker at a pack. Nil where there is no
    /// composer to open — the button is then absent rather than inert.
    var openStickerPack: ((String) -> Void)? = nil
    /// Previews a discoverable source server — see `ExpressionSourceRow`.
    var previewGuild: ((GuildID) -> Void)? = nil

    private static let width: CGFloat = 300
    private static let artSide: CGFloat = 48

    /// Whether the still under the moving emoji has been taken away. See `art`.
    @State private var isPlaying = false

    /// Whether there is a moving form to put up at all.
    ///
    /// **Read beside the latch, and that is what stops it sticking.** Only the
    /// film can clear `isPlaying`, and a filmstrip that is dismantled reports
    /// nothing on the way out — `AnimatedDecoration.tearDown` bumps its
    /// generation precisely so a report in flight is dropped. So any of the
    /// three conditions below going false while the card is open leaves the
    /// still hidden over a film that is no longer there: an emoji card that is
    /// blank, on the one surface somebody opened in order to look at the emoji.
    /// `AvatarView` keeps the same pair of guards, for the same defect.
    private var artPlays: Bool {
        guard let url = info.artURL, CDN.canAnimate(url) else { return false }
        return AnimationClock.playsAnimatedEmoji
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                art
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    detail
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.margin)

            if let pack = info.pack {
                PackSection(pack: pack, openStickerPack: openStickerPack)
            }

            if let source = info.source {
                Divider().opacity(0.35)
                ExpressionSourceRow(source: source, openGuild: openGuild, previewGuild: previewGuild)
            }
        }
        .frame(width: Self.width)
        // No material or shadow of its own: the popover's glass is the body
        // and it casts its own shadow — §4.9.
    }

    /// The sentence under the title.
    ///
    /// **Discord's own words for one of its stickers** — `auckXz` and
    /// `OzB6e3` in the en-US strings — with the pack's name set in weight.
    @ViewBuilder
    private var detail: some View {
        if let pack = info.pack {
            let name = Text(pack.name).fontWeight(.semibold)
            if pack.isOffered {
                Text("This is a \(name) sticker.")
            } else {
                Text("This is a \(name) sticker. They’re no longer available.")
            }
        } else {
            Text(info.detail)
        }
    }

    /// The picture, at the size the card draws art at.
    ///
    /// A Unicode emoji is text and needs no fetch at all. A sticker plays in
    /// whatever format it is in — see `StickerArt`.
    @ViewBuilder
    private var art: some View {
        if let sticker = info.sticker {
            StickerArt(sticker: sticker, side: Self.artSide)
        } else if let glyph = info.glyph {
            ExpressionGlyph(emoji: EmojiRef(name: glyph), side: Self.artSide)
        } else {
            RemoteImage(url: info.artURL, side: Self.artSide, bucket: .artwork) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.surfaceRaised)
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.artSide, height: Self.artSide)
            .opacity(isPlaying && artPlays ? 0 : 1)
            // **The still is only half of an animated emoji**, and this card is
            // the one place somebody asked to look at one closely — which is
            // exactly where a frozen first frame is most obviously wrong. The
            // same two-layer arrangement `AvatarView` and the rail tile use: the
            // moving form over the still, and `onPlayback` takes the still away
            // so an asset with a soft rim is not two offset copies.
            //
            // Gated on the address, not attempted for everything: Discord serves
            // an animated emoji as `.gif` and a still one as `.png`, so there is
            // nothing to discover — `CDN.canAnimate` is that fact everywhere.
            .overlay {
                if artPlays, let url = info.artURL {
                    AnimatedDecoration(
                        url: url,
                        side: Self.artSide,
                        onPlayback: { playing in
                            guard isPlaying != playing else { return }
                            isPlaying = playing
                        }
                    )
                    .frame(width: Self.artSide, height: Self.artSide)
                    .allowsHitTesting(false)
                }
            }
            // An emoji that changes has to put its still back while the new one
            // resolves, or the card is empty in between.
            .onChange(of: info.artURL) { isPlaying = false }
        }
    }
}

/// The rest of one of Discord's own sticker packs, and the way into it.
///
/// **Discord's card, in this app's materials** (`s4` in module `30020925`):
/// three more stickers from the pack, playing, and "View More Stickers", which
/// opens the picker at that pack. The button is there only for a pack Discord
/// still offers and only where a composer can open — a retired pack has nothing
/// to browse to, and a button with nowhere to go is the inert control §5.5
/// forbids.
private struct PackSection: View {
    var pack: ExpressionInfo.Pack
    var openStickerPack: ((String) -> Void)?

    /// Discord's size for the pack's samples.
    private static let sampleSide: CGFloat = 80

    var body: some View {
        VStack(spacing: Spacing.snug) {
            if !pack.samples.isEmpty {
                HStack(spacing: 0) {
                    ForEach(pack.samples, id: \.id) { sticker in
                        StickerArt(sticker: sticker, side: Self.sampleSide)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if pack.isOffered, let openStickerPack {
                Button { openStickerPack(pack.sectionID) } label: {
                    Text("View More Stickers")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityHint("Opens the sticker picker at \(pack.name)")
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
    }
}

/// Where an expression came from.
///
/// **A server the reader is not in is still worth naming**, and until
/// `GET /emojis/{id}/source` was wired this card could only say "a server you
/// are not in" — which is the one thing the reader had already worked out from
/// the picture in front of them.
///
/// A button where the reader can act on it and a plain block where they cannot —
/// the same rule the tag card's footer follows. A control that looks like a
/// control and does nothing is worse than a line of text.
///
/// Everything below the name is withheld for a **private** server. The route
/// answers for one because it is scoped to the emoji rather than to the server,
/// and publishing a closed community's size because one of its emoji leaked out
/// is the client doing something nobody asked it to.
struct ExpressionSourceRow: View {
    var source: ExpressionInfo.Source
    var openGuild: (GuildID) -> Void
    /// Looks inside a discoverable server the reader is not in — Discord's
    /// preview, captured in `pressing on emoji join server preview mode.har`
    /// as the tag card's Join. Nil where the surface cannot open one.
    var previewGuild: ((GuildID) -> Void)? = nil

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(heading)
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)

            if source.isLoading {
                HStack(spacing: Spacing.base) {
                    ProgressView().controlSize(.small)
                    Text(source.name)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                }
            } else if let guildID = source.guildID, source.isJoined {
                Button { openGuild(guildID) } label: { row }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        // A `@State` write of an equal value still invalidates.
                        guard isHovering != hovering else { return }
                        isHovering = hovering
                    }
                    .animation(motion.hover, value: isHovering)
                    .accessibilityHint("Open this server")
            } else if let guildID = joinableGuildID, let previewGuild {
                // A discoverable server is a way in too: its row previews it,
                // as Discord's does (`639245`).
                Button { previewGuild(guildID) } label: { row }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        guard isHovering != hovering else { return }
                        isHovering = hovering
                    }
                    .animation(motion.hover, value: isHovering)
                    .accessibilityHint("Preview this server")
            } else {
                row
            }

            if let description = source.description, !description.isEmpty {
                Text(description)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !source.sample.isEmpty {
                sampleStrip
            }

            // Discord's Join Server (`450707`'s `JOIN_GUILD`): a discoverable
            // server the reader is not in. It opens the server to look at, the
            // tag card's Join.
            if let guildID = joinableGuildID, let previewGuild {
                Button { previewGuild(guildID) } label: {
                    Label("Join Server", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
    }

    /// The server a Join can open: one the reader is not in, that is open to
    /// be looked at.
    private var joinableGuildID: GuildID? {
        guard !source.isJoined, source.isDiscoverable else { return nil }
        return source.guildID
    }

    private var heading: String {
        if source.isJoined { return "FROM YOUR SERVER" }
        return source.guildID == nil ? "FROM" : "FROM THE SERVER"
    }

    private var row: some View {
        HStack(spacing: Spacing.base) {
            AnimatedPicture(url: source.iconURL, side: Metrics.avatarMessage, contentMode: .fill) {
                Text(source.monogram)
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Metrics.avatarMessage, height: Metrics.avatarMessage)
                    .background(Palette.surfaceRaised)
            }
            .clipShape(.rect(cornerRadius: Metrics.avatarMessage * 0.3, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.tight) {
                    Text(source.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let mark = source.mark {
                        GuildMarkBadge(mark: mark, side: 13)
                    }
                }
                if let counts {
                    Text(counts)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if source.isJoined {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(InkColor.tertiary)
                    .opacity(isHovering ? 1 : 0.45)
            }
        }
        // The ground grows OUTWARD from the row rather than the row being padded
        // in and back out, so the icon still lines up with the heading above it.
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Palette.hoverFill)
                .opacity(isHovering ? 1 : 0)
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
        }
        .contentShape(.rect)
    }

    /// "596 Online · 1,916 Members", with whichever halves are known.
    ///
    /// Absent rather than zero when the route did not send them: "0 Online" on a
    /// server of two thousand is a worse answer than no line at all.
    private var counts: String? {
        var parts: [String] = []
        if let online = source.onlineCount { parts.append("\(online.formatted(.number)) Online") }
        if let members = source.memberCount {
            parts.append("\(members.formatted(.number)) Members")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// A few of the server's other emoji.
    ///
    /// **A picture of what a place is like**, which answers "should I care about
    /// this server" far better than a member count does — and it is free, since
    /// the source route sends them beside everything else.
    private var sampleStrip: some View {
        HStack(spacing: Spacing.base) {
            ForEach(source.sample) { item in
                // A Lottie sticker has no bitmap on the CDN, so its poster is
                // the first frame of a rasterised strip — which `RemoteImage`
                // already routes by extension. An animated emoji plays, as it
                // does in the message it came from.
                AnimatedPicture(url: item.url, side: Self.sampleSide) {
                    Color.clear
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private static let sampleSide: CGFloat = 24
}
