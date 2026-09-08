import SwiftUI
import WingcordCore

/// One server in the discovery grid.
///
/// **The counts are pinned to the foot and the description is not.** That is the
/// one arrangement fact worth stating: a grid whose cards are each as tall as
/// their own description has ragged rows, and a server with a one-line
/// description sitting beside one with three would pull its footer up to meet
/// the neighbour's second line. So the description takes a fixed measure of
/// three lines and the counts sit under a `Spacer` — a card is a uniform object
/// whatever is written in it.
struct DiscoveryServerCard: View {
    var card: DiscoveryCard
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    /// Three lines of description, reserved whether or not there are three.
    private static let descriptionLines = 3

    private var shape: RoundedRectangle {
        .rect(cornerRadius: Radius.card, style: .continuous)
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                VStack(alignment: .leading, spacing: Spacing.base) {
                    name
                    description
                    Spacer(minLength: Spacing.base)
                    counts
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.snug)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            // Structure, not glass: this sits on the opaque reading surface,
            // where a material has nothing to lens — §4 rule 3.
            .structuralSurface(in: shape)
            .overlay {
                shape.strokeBorder(
                    isHovering ? AnyShapeStyle(Ink.tertiary) : AnyShapeStyle(Ink.quaternary),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // Guarded rather than written unconditionally: `.onHover` compiles to an
        // AppKit tracking area, and one per card in a scrolling grid is geometry
        // AppKit re-derives every frame of every scroll. One is unavoidable
        // here; the guard is on the state write inside it.
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    /// The wide picture, with the server's mark overlapping its foot.
    ///
    /// **A region that reserves its own height**, so a server with no artwork is
    /// a card of the same size rather than a shorter one — see the note above
    /// about ragged rows. What fills it when there is nothing is the page's own
    /// raised surface, which is a real state rather than a placeholder.
    private var artwork: some View {
        Rectangle()
            .fill(Palette.surfaceRaised)
            .frame(height: Metrics.discoveryCardArt)
            .overlay {
                if let url = card.artworkURL {
                    RemoteImage(url: url, side: Metrics.discoveryCardWidth, bucket: .attachment) {
                        Color.clear
                    }
                    .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                // Overlapping the artwork's foot, which is where a server's mark
                // goes on every surface in this app that pairs the two.
                ServerMark(url: card.iconURL, monogram: card.monogram)
                    .padding(.leading, Spacing.snug)
                    .offset(y: Metrics.discoveryCardIcon / 3)
            }
            // The mark hangs past the artwork, so the row under it starts lower.
            .padding(.bottom, Metrics.discoveryCardIcon / 3)
            .accessibilityHidden(true)
    }

    private var name: some View {
        HStack(spacing: Spacing.tight) {
            if let standing = card.standing {
                GuildStandingBadge(standing: standing, side: 15)
            }
            Text(card.name)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if card.isJoined {
                Text("JOINED")
                    .font(Typeface.categoryHeader)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, Spacing.tight)
                    .padding(.vertical, 1)
                    .background(Palette.hoverFill, in: .capsule)
            }
            Spacer(minLength: 0)
        }
    }

    private var description: some View {
        Text(card.description ?? "")
            .font(Typeface.rowSubtitle)
            .foregroundStyle(Ink.secondary)
            .lineLimit(Self.descriptionLines, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var counts: some View {
        HStack(spacing: Spacing.snug) {
            count(card.onlineCount, "Online", tint: Palette.presenceOnline)
            count(card.memberCount, "Members", tint: Palette.presenceOffline)
            Spacer(minLength: 0)
        }
    }

    private func count(_ value: Int, _ label: String, tint: Color) -> some View {
        HStack(spacing: Spacing.tight) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text("\(Self.compact(value)) \(label)")
                .font(Typeface.metadata)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
        }
    }

    /// `4.5M`, not `4,453,182`.
    ///
    /// **Two cards side by side is what decides this.** The exact figure is nine
    /// characters of monospaced-ish digits that push the second count off the
    /// card, and nobody chooses a server on the difference between 4,453,182 and
    /// 4.5 million. `.notation(.compactName)` is the system's, so it localises.
    private static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private var accessibilityLabel: String {
        var parts = [card.name]
        if card.isJoined { parts.append("joined") }
        if let description = card.description { parts.append(description) }
        parts.append("\(card.memberCount) members, \(card.onlineCount) online")
        return parts.joined(separator: ", ")
    }
}

/// A server's mark: a squircle, because that is what a server is everywhere else
/// in this app — the rail, the forward sheet, the tag card.
private struct ServerMark: View {
    var url: URL?
    var monogram: String

    private var shape: RoundedRectangle {
        .rect(cornerRadius: Metrics.discoveryCardIcon * 0.28, style: .continuous)
    }

    var body: some View {
        RemoteImage(url: url, side: Metrics.discoveryCardIcon) {
            Text(monogram)
                .font(.system(size: Metrics.discoveryCardIcon * 0.36, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: Metrics.discoveryCardIcon, height: Metrics.discoveryCardIcon)
                .background(Palette.surfaceRaised)
        }
        .frame(width: Metrics.discoveryCardIcon, height: Metrics.discoveryCardIcon)
        .clipShape(shape)
        // A rim, because the mark lies on artwork nobody chose and a dark icon
        // on a dark picture has no edge at all.
        .overlay { shape.strokeBorder(Palette.canvas, lineWidth: 2) }
    }
}

// MARK: - Apps

/// One app in the directory grid.
///
/// **The same card a server gets, with a moving picture in it.** The banner, the
/// mark riding its foot, the three-line measure and the counts pinned to the
/// bottom are all the server card's arrangement — two grids that share a bar
/// must share a shape — and the one thing an app has that a server has not is a
/// preview loop.
///
/// **Only the hovered tile ever builds a player.** A page of the directory is
/// forty-eight apps and a third of them carry a video; forty-eight
/// `AVPlayer`s is forty-eight decoders and forty-eight connections for one
/// picture anybody is looking at. The loop is created on the pointer arriving
/// and torn down on it leaving — `LoopingVideo.dismantleNSView` releases the
/// player, the looper and the layer — and the still stays underneath it, so
/// nothing flashes black while the first frame is fetched. The still *is* that
/// frame where the app has no other artwork: see `AppModel.appBannerURL`.
struct DiscoveryAppTile: View {
    var card: DiscoveryAppCard
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    /// Shared, so a grid of forty-eight tiles derives each colour once.
    private var gradients: AppIconGradientStore { .shared }

    /// Three lines of tagline, reserved whether or not there are three — the
    /// server card's note applies word for word.
    private static let descriptionLines = 3

    private var shape: RoundedRectangle {
        .rect(cornerRadius: Radius.card, style: .continuous)
    }

    /// Whether anything is moving on this tile right now.
    ///
    /// **Reduce Motion holds the still.** A silent decorative loop is exactly
    /// the motion that setting exists to stop, and the still underneath is the
    /// picture it would have shown anyway.
    private var isPlaying: Bool {
        isHovering && !motion.reduceMotion
            && (card.videoURL != nil || card.animatedBannerURL != nil)
    }

    /// The layer that appears under the pointer.
    ///
    /// **The loop, or the banner's own film, never both** — which is Discord's
    /// own arrangement rather than a choice: its component passes
    /// `animatedUrl: undefined` down the video branch, so an app with a preview
    /// video never shows its animated banner. The projection already resolves
    /// that; this is the pair of layers it decides between.
    @ViewBuilder
    private var hoverLayer: some View {
        if let url = card.videoURL {
            LoopingVideo(url: url)
        } else if let url = card.animatedBannerURL {
            // Stacked over the `RemoteImage` below, which is drawing this same
            // asset's first frame — the sidebar banner's arrangement exactly.
            AnimatedDecoration(
                url: url,
                side: Metrics.discoveryCardWidth,
                gravity: .resizeAspectFill,
                byteBudget: Self.filmBudget
            )
        }
    }

    /// What one tile's filmstrip may hold.
    ///
    /// **A banner frame is two orders of magnitude larger than a decoration's**,
    /// which the default budget is sized for — 300 points wide at 16:9 is around
    /// 400 KB a frame, so the default would buy a fifteen-frame loop about
    /// three of them. One tile animates at a time and it is evicted when the
    /// pointer leaves, so the trade is the sidebar banner's.
    private static let filmBudget = 12 * 1024 * 1024

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                VStack(alignment: .leading, spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: 2) {
                        name
                        // Between the name and the description, which is where
                        // Discord's own card puts it.
                        if let category = card.category {
                            Text(category)
                                .font(Typeface.metadata)
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(card.subtitle)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(Self.descriptionLines, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: Spacing.base)
                    servers
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.snug)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .structuralSurface(in: shape)
            .overlay {
                shape.strokeBorder(
                    isHovering ? AnyShapeStyle(Ink.tertiary) : AnyShapeStyle(Ink.quaternary),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // Guarded rather than written unconditionally: `.onHover` compiles to an
        // AppKit tracking area, and one per card in a scrolling grid is geometry
        // AppKit re-derives every frame of every scroll. One is unavoidable
        // here; the guard is on the state write inside it.
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        // **Only for a tile with nothing else to draw.** The store is
        // idempotent, so a cell scrolling back into view costs a dictionary
        // lookup rather than a second decode.
        .task(id: card.id) {
            guard card.bannerURL == nil, card.accentColor == nil else { return }
            await gradients.resolve(card.id, iconHash: card.iconHash)
        }
        .animation(motion.fade, value: gradients.gradient(for: card.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    /// The banner, the loop over it, and the app's mark on the seam.
    ///
    /// **A region that reserves its own height**, so an app with no artwork is a
    /// card of the same size rather than a shorter one. 16:9 rather than the
    /// server card's 2:1 — every `activity_preview_video` in the captures is
    /// 16:9, and cropping a video to a shape it was not shot at is the one thing
    /// here that cannot be corrected later.
    private var artwork: some View {
        Rectangle()
            // The bot's own accent where it set one; otherwise the two stops
            // Discord derives from the icon — see `AppIconGradient`, which is a
            // port of its own module and matches its output byte for byte.
            .fill(card.accentColor ?? Palette.surfaceRaised)
            .frame(height: Metrics.discoveryAppArt)
            .overlay {
                if card.bannerURL == nil, card.accentColor == nil,
                   let gradient = gradients.gradient(for: card.id)
                {
                    gradient.fill.transition(.opacity)
                }
            }
            .overlay {
                if card.bannerURL != nil {
                    RemoteImage(
                        url: card.bannerURL,
                        side: Metrics.discoveryCardWidth,
                        bucket: .artwork
                    ) {
                        Color.clear
                    }
                    .scaledToFill()
                }
            }
            .overlay {
                if isPlaying {
                    // A fade rather than a cut: both films start on the frame
                    // the still already shows, so the two are the same picture
                    // and the crossing should not be visible as an event.
                    hoverLayer.transition(.opacity)
                }
            }
            .clipped()
            .animation(motion.fade, value: isPlaying)
            .overlay(alignment: .bottomLeading) {
                // Overlapping the artwork's foot, which is where a mark goes on
                // every surface in this app that pairs one with a picture.
                AppMark(row: card.row)
                    .padding(.leading, Spacing.snug)
                    .offset(y: Metrics.discoveryAppIcon / 3)
            }
            // The mark hangs past the artwork, so the row under it starts lower.
            .padding(.bottom, Metrics.discoveryAppIcon / 3)
            .accessibilityHidden(true)
    }

    private var name: some View {
        HStack(spacing: Spacing.tight) {
            Text(card.name)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if card.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(Palette.presenceOnline)
            }
            Spacer(minLength: 0)
        }
    }

    /// Where a server card puts two counts, an app has one — and it is the only
    /// number the directory answers with, so it holds the foot on its own.
    @ViewBuilder
    private var servers: some View {
        if let count = card.guildCount, count > 0 {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "server.rack")
                    .font(.system(.caption2))
                Text("\(count.formatted(.number.notation(.compactName))) servers")
                    .font(Typeface.metadata)
                    .lineLimit(1)
            }
            .foregroundStyle(Ink.tertiary)
        }
    }

    private var accessibilityLabel: String {
        var parts = [card.name]
        if card.isVerified { parts.append("verified") }
        parts.append(card.subtitle)
        if let count = card.guildCount, count > 0 { parts.append("in \(count) servers") }
        return parts.joined(separator: ", ")
    }
}

/// An app's mark on a tile: the launcher's own icon with a rim.
///
/// The rim is `ServerMark`'s and for its reason — the mark lies on artwork
/// nobody chose, and a dark icon on a dark picture has no edge at all.
private struct AppMark: View {
    var row: ActivityRow

    private var shape: RoundedRectangle {
        .rect(cornerRadius: Metrics.discoveryAppIcon * 0.28, style: .continuous)
    }

    var body: some View {
        ActivityIcon(row: row, side: Metrics.discoveryAppIcon)
            .overlay { shape.strokeBorder(Palette.canvas, lineWidth: 2) }
    }
}

// MARK: - An app in a list

/// One app as a row: a mark, a name and a line.
///
/// **The tile's own facts at a tenth of its height**, for the one place an app
/// appears in a list rather than a grid — "You might also like" under an app's
/// own page. A stack of banner cards there would be a second directory under the
/// page instead of a suggestion, which is what Discord draws and why.
struct DiscoveryAppRow: View {
    var card: DiscoveryAppCard
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.snug) {
                ActivityIcon(row: card.row, side: Metrics.activityRowIcon)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.tight) {
                        Text(card.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if card.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(.caption2))
                                .foregroundStyle(Palette.presenceOnline)
                        }
                    }
                    Text(card.subtitle)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.base)
                if let count = card.guildCount, count > 0 {
                    Text("\(count.formatted(.number.notation(.compactName)))")
                        .font(Typeface.metadata)
                        .foregroundStyle(Ink.quaternary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.base)
            .background(
                isHovered ? Palette.hoverFill : .clear,
                in: .rect(cornerRadius: Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovered != hovering else { return }
            isHovered = hovering
        }
        .animation(motion.hover, value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(card.name), \(card.subtitle)"))
        .accessibilityAddTraits(.isButton)
    }
}
