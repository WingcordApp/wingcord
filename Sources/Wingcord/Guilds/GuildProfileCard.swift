import SwiftUI
import WingcordCore

/// The card behind a server tag.
///
/// **Everything here is either the server's own content or a fact about it**,
/// which is the same rule the profile card is built on: the artwork, the icon
/// and the trait emoji are the server's colour, and the chrome around them is
/// achromatic glass. The one exception is the standing rosette, which is a mark
/// Discord issues rather than a decoration this app chose.
///
/// **No Join button.** This client cannot join a server, and a filled green
/// button that does nothing is a promise the app cannot keep — the reader
/// presses it once and stops trusting every other control on the surface. A
/// server the reader is already in gets the action that *is* real: go there.
struct GuildProfileCard: View {
    var profile: GuildProfilePresentation
    var openGuild: (GuildID) -> Void
    /// Joins, or opens the server's application form. Nil on a surface with
    /// nothing to join with, which draws the plain sentence instead — §5.5.
    var enterGuild: ((GuildID) -> Void)?

    @Environment(\.motion) private var motion
    /// One press, and the button says so. The card can be reopened while the
    /// request is still out.
    @State private var isEntering = false

    private static let width: CGFloat = 320
    private static let bannerHeight: CGFloat = 118
    private static let iconSide: CGFloat = 56
    /// How far the icon hangs below the artwork.
    private static let iconDrop: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            identity
            counts
            if let description = profile.description, !description.isEmpty {
                Text(description)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.snug)
            }
            if !profile.traits.isEmpty {
                TraitFlow(traits: profile.traits)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.snug)
            }
            footer
        }
        .frame(width: Self.width)
        // Clear glass, like every other flyout — see `ExpressionInfoCard`. What
        // passes under a floating card here is content, and `.regular` frosts it
        // into a grey slab instead of lensing it.
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Radius.card, style: .continuous)
        )
        .shadow(color: .black.opacity(0.4), radius: 28, y: 10)
    }

    // MARK: Header

    /// The banner, with the icon cut out of it.
    ///
    /// Built exactly like a profile's: the gap around the icon is a **hole** in
    /// the artwork rather than a stroke painted over it, so what shows through
    /// is the card's own ground. A stroke would be a hard black outline stuck to
    /// the icon on every dark banner, which is most of them.
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            // `Color.clear` with the picture as an OVERLAY, never as a sibling:
            // an aspect-filled image reports the image's size to layout and
            // takes the whole card with it.
            Color.clear
                .background { bannerPlate }
                .overlay {
                    if let bannerURL = profile.bannerURL {
                        RemoteImage(url: bannerURL, side: Self.width, bucket: .artwork) {
                            Color.clear
                        }
                        .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(height: Self.bannerHeight)
                .clipped()
                .mask(alignment: .bottomLeading) { iconMask }

            icon
                .frame(width: Self.iconSide, height: Self.iconSide)
                .clipShape(.rect(cornerRadius: Self.iconSide * 0.3, style: .continuous))
                .padding(.leading, Spacing.margin)
                .offset(y: Self.iconDrop)
        }
        .padding(.bottom, Self.iconDrop)
    }

    /// What stands behind the banner while it loads, and instead of it when
    /// there is none — the server's own badge colours, which is the only palette
    /// on this card that belongs to the server rather than to the app.
    private var bannerPlate: some View {
        let primary = profile.badgeColorPrimary.map { Color(hex: $0) } ?? Palette.surfaceRaised
        let secondary = profile.badgeColorSecondary.map { Color(hex: $0) } ?? primary
        return LinearGradient(
            colors: [primary.opacity(0.85), secondary.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var iconMask: some View {
        Rectangle()
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: Self.iconSide * 0.42, style: .continuous)
                    .frame(width: Self.iconSide + 10, height: Self.iconSide + 10)
                    .padding(.leading, Spacing.margin - 5)
                    .offset(y: Self.iconDrop + 5)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    private var icon: some View {
        RemoteImage(url: profile.iconURL, side: Self.iconSide) {
            Text(profile.monogram)
                .font(.system(size: Self.iconSide * 0.3, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .background(Palette.surfaceRaised)
        }
        .frame(width: Self.iconSide, height: Self.iconSide)
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: Spacing.base) {
            Text(profile.name)
                .font(.system(.headline, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            if let standing = profile.standing {
                GuildStandingBadge(standing: standing)
            }
            if let tag = profile.tag {
                // **Deliberately not a destination.** Every other tag chip in
                // the app opens this card; one inside it would open a card for
                // the server already on screen.
                GuildTagChip(tag: GuildTag(text: tag, badgeURL: profile.badgeURL, guildID: nil))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.margin)
    }

    /// Online, members, and the year — the three numbers that say what kind of
    /// place this is before a word of the description is read.
    ///
    /// The counts are absent rather than zero when the route did not send them:
    /// "0 Online" on a server with fifty thousand people is a worse answer than
    /// no line at all.
    private var counts: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.base) {
                if let online = profile.onlineCount {
                    CountDot(
                        tint: Palette.presenceOnline,
                        label: "\(online.formatted(.number)) Online"
                    )
                }
                if let members = profile.memberCount {
                    CountDot(
                        tint: Palette.presenceOffline,
                        label: "\(members.formatted(.number)) Members"
                    )
                }
            }
            .font(.system(.caption))

            Text("Est. \(profile.createdAt.formatted(.dateTime.month(.abbreviated).year()))")
                .font(.system(.caption))
                .foregroundStyle(InkColor.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.tight)
    }

    // MARK: Footer

    /// Join, or apply to join.
    ///
    /// **`.glass`, like Open Server above it**, rather than Discord's green
    /// slab: this card is one of the app's flyouts and the affirmative control
    /// on it is the same object the joined case already draws. §4 — a second
    /// material on a surface that already has one is glass on glass.
    @ViewBuilder
    private var entryButton: some View {
        let isApplying = profile.entry == .apply
        Button { enter() } label: {
            Label(
                isApplying ? "Apply to Join" : "Join",
                systemImage: isApplying ? "square.and.pencil" : "plus"
            )
            .font(.system(.subheadline, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.base)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .disabled(isEntering)
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.snug)
        .padding(.bottom, Spacing.margin)
    }

    private var notInThisServer: some View {
        // **Two different facts, and they used to be one sentence.** A server
        // the reader is simply not in still has a name, an icon and a date; a
        // server that has *limited who can see its profile* has none of those,
        // and telling that reader they are "not in this server" answers a
        // question they did not ask while leaving the empty card unexplained.
        Text(profile.isUnnamed
            ? "The server has limited who can see this profile."
            : "You are not in this server.")
            .font(Typeface.rowSubtitle)
            .foregroundStyle(InkColor.tertiary)
            .padding(.horizontal, Spacing.margin)
            .padding(.top, Spacing.snug)
            .padding(.bottom, Spacing.margin)
    }

    private func enter() {
        guard !isEntering else { return }
        isEntering = true
        enterGuild?(profile.guildID)
    }

    @ViewBuilder
    private var footer: some View {
        if profile.isJoined {
            Button { openGuild(profile.guildID) } label: {
                Label("Open Server", systemImage: "arrow.forward")
                    .font(.system(.subheadline, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.base)
                    .contentShape(.rect)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, Spacing.margin)
            .padding(.top, Spacing.snug)
            .padding(.bottom, Spacing.margin)
        } else if profile.isLoading {
            HStack(spacing: Spacing.base) {
                ProgressView().controlSize(.small)
                Text("Loading server…")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, Spacing.snug)
        } else {
            // **The way in, and it was there all along.** This used to say
            // "You are not in this server." and stop, on the reading that the
            // client had no route for it — it has had one since discovery
            // shipped. Which of the two acts is offered is the server's own
            // answer; see `AppModel.guildEntry`.
            switch profile.entry {
            case .join, .apply:
                // **A surface with no opener draws the sentence instead.** An
                // inert Join is exactly the control §5.5 forbids.
                if enterGuild == nil { notInThisServer } else { entryButton }
            case .none:
                notInThisServer
            case .pending:
                // Applied, and waiting. Not a control: withdrawing is a
                // decision with a confirmation behind it and it belongs beside
                // the server, not on a hover card.
                Label("Your application is pending.", systemImage: "hourglass")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.snug)
                    .padding(.bottom, Spacing.margin)
            }
        }
    }

}

/// One count, with the dot that names what it counts.
private struct CountDot: View {
    var tint: Color
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(InkColor.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The words a server describes itself with.
///
/// Capped, with the remainder counted. A server may carry five and the card is
/// 320 points wide; three rows of chips would push the description off the
/// bottom of the thing they are meant to summarise.
private struct TraitFlow: View {
    var traits: [GuildTrait]

    private static let visible = 4

    var body: some View {
        let shown = traits.prefix(Self.visible)
        let overflow = traits.count - shown.count
        FlowLayout(spacing: Spacing.tight) {
            ForEach(shown) { trait in
                HStack(spacing: 4) {
                    if let glyph = trait.glyph {
                        Text(glyph).font(.system(size: 11))
                    } else if let id = trait.emojiID {
                        RemoteImage(
                            url: CDN.emoji(id: id, animated: trait.emojiAnimated, side: 12),
                            side: 12
                        ) { Color.clear }
                        .frame(width: 12, height: 12)
                    }
                    Text(trait.label)
                        .font(.system(.caption2))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassEffect(.clear, in: .rect(cornerRadius: 8))
            }
            if overflow > 0 {
                Text("+ \(overflow) more")
                    .font(.system(.caption2))
                    .foregroundStyle(InkColor.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
            }
        }
    }
}
