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
/// **The same card as a server's, one field shorter.** An app has no member
/// counts and no rosette of its own — what it has is a verified mark and a
/// tagline — so the footer carries its tags instead. Two card *types* rather
/// than one with optionals: the two grids never mix, and a single card carrying
/// both shapes would be a `switch` in a view body that runs per cell.
struct DiscoveryAppCard: View {
    var app: ActivityApp
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let descriptionLines = 3

    private var shape: RoundedRectangle {
        .rect(cornerRadius: Radius.card, style: .continuous)
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                // The launcher's own icon view, fed through the launcher's own
                // row projection — one resolution of "what does an app look
                // like", not a second.
                ActivityIcon(row: AppModel.row(for: app), side: Metrics.activityRowIcon)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(spacing: Spacing.tight) {
                        Text(app.name)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if app.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(.caption2))
                                .foregroundStyle(Palette.presenceOnline)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(app.rowSubtitle)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(Self.descriptionLines, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    if let guildCount = app.guildCount, guildCount > 0 {
                        Text("\(guildCount.formatted(.number.notation(.compactName))) servers")
                            .font(Typeface.metadata)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
            }
            .padding(Spacing.snug)
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
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(app.name), \(app.rowSubtitle)"))
        .accessibilityAddTraits(.isButton)
    }
}
