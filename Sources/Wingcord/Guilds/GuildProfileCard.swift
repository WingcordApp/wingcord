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
    /// Opens a game's own page. Nil on a surface with nowhere to send anybody,
    /// which draws the icons as pictures rather than as controls — §5.5.
    var openGame: ((ApplicationID) -> Void)?
    /// Joins, or opens the server's application form. Nil on a surface with
    /// nothing to join with, which draws the plain sentence instead — §5.5.
    var enterGuild: ((GuildID) -> Void)?
    /// Whether the card ends in its way in. Off where the card is the header
    /// of the act itself — the application form, Discord's `disableCTA`.
    var showsEntry = true
    /// "Unable to load server profile", pressed. Nil where nothing can ask
    /// again, which draws the line without the press.
    var retry: (() -> Void)? = nil

    @Environment(\.motion) private var motion
    @Environment(\.colorScheme) private var colorScheme
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
            refusalLine
            if let description = profile.description, !description.isEmpty {
                Text(description)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.snug)
            }
            // **Above the traits, which is where Discord puts it.** A trait is
            // a word somebody typed about the server; a game is a thing you can
            // go and look at, so it sits with the description it follows from.
            if !profile.games.isEmpty {
                GuildProfileGameRow(games: profile.games, open: openGame)
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
        // No material of its own: the popover's glass is the body — §4.9.
        // The popover casts its own shadow; a second would double it.
    }

    /// Discord's words for a profile it would not show (`109026`): the
    /// server limited who sees it, or it failed — in the warning ink, with
    /// the line itself the way to try again.
    @ViewBuilder
    private var refusalLine: some View {
        switch profile.refusal {
        case .limited:
            Text("The server has limited who can see this profile.")
                .font(.system(.caption))
                .foregroundStyle(InkColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.margin)
                .padding(.top, Spacing.snug)
        case .failed:
            Button { retry?() } label: {
                Label("Unable to load server profile", systemImage: "arrow.clockwise")
                    .font(.system(.caption))
                    .foregroundStyle(Palette.feedbackWarning)
            }
            .buttonStyle(.plain)
            .disabled(retry == nil)
            .padding(.horizontal, Spacing.margin)
            .padding(.top, Spacing.snug)
        case nil:
            EmptyView()
        }
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
    /// there is none — Discord's glow of the server's own colour, the one the
    /// invite card draws too. See `GuildBannerArt`.
    private var bannerPlate: some View {
        let colour = profile.bannerColor ?? GuildBannerArt.defaultColour(isLight: colorScheme == .light)
        return Canvas { context, size in
            context.withCGContext { cg in
                GuildBannerArt.drawGlow(colour, in: CGRect(origin: .zero, size: size), context: cg)
            }
        }
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

    /// The server's own picture, or a monogram where there is none.
    ///
    /// **Not the tag's badge.** That was tried and reverted: a private server
    /// answers the profile route with nothing, so the plate fell back to `?` —
    /// and the badge *is* available, off the person wearing the tag. But the
    /// badge is a mark that belongs beside the letters, and blown up onto the
    /// server's avatar plate it reads as the server's icon, which it is not.
    /// The chip above the card already wears it; the plate says, honestly, that
    /// there is no picture to show.
    private var icon: some View {
        // An animated icon plays, as it does on the rail.
        AnimatedPicture(url: profile.iconURL, side: Self.iconSide, contentMode: .fill) {
            Text(profile.monogram)
                .font(.system(size: Self.iconSide * 0.3, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .background(ProfileFlyoutGround.raised(in: colorScheme))
        }
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: Spacing.base) {
            Text(profile.name)
                .font(.system(.headline, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            if let mark = profile.mark {
                GuildMarkBadge(mark: mark)
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
    /// **A standard bordered button, like Open Server**, rather than Discord's
    /// green slab: this card is one of the app's flyouts and the affirmative
    /// control on it is the same object the joined case already draws.
    @ViewBuilder
    private var entryButton: some View {
        let isApplying = profile.entry == .apply
        Button { enter() } label: {
            Label(
                isApplying ? "Apply to Join" : "Join",
                systemImage: isApplying ? "square.and.pencil" : "plus"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(isEntering)
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.snug)
        .padding(.bottom, Spacing.margin)
    }

    private var isLimitedAbove: Bool {
        if case .limited = profile.refusal { return true }
        return false
    }

    /// The foot of a card with no way in to offer.
    ///
    /// **Discord's one sentence, and only where it has one.** A server that
    /// has *limited who can see its profile* gets its words for that
    /// (`8mfCqY`); a server the reader is simply not in gets nothing — its
    /// name and icon already say whose it is, and "You are not in this
    /// server" was this client's sentence, never Discord's.
    @ViewBuilder
    private var notInThisServer: some View {
        // Said once: where the refusal line above already says it, the foot
        // doesn't say it again in a smaller hand (his image 259, 2026-11-19).
        if profile.isUnnamed, !isLimitedAbove {
            Text("The server has limited who can see this profile.")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(InkColor.tertiary)
                .padding(.horizontal, Spacing.margin)
                .padding(.top, Spacing.snug)
                .padding(.bottom, Spacing.margin)
        } else {
            Color.clear.frame(height: Spacing.margin)
        }
    }

    private func enter() {
        guard !isEntering else { return }
        isEntering = true
        enterGuild?(profile.guildID)
    }

    @ViewBuilder
    private var footer: some View {
        if !showsEntry {
            Color.clear.frame(height: Spacing.margin)
        } else if profile.isJoined {
            Button { openGuild(profile.guildID) } label: {
                Label("Open Server", systemImage: "arrow.forward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
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
            // **The way in, and it was there all along.** This used to stop
            // at a sentence, on the reading that the client had no route for
            // it — it has had one since discovery shipped. Which of the two
            // acts is offered is the server's own answer; see
            // `AppModel.guildEntry`.
            switch profile.entry {
            case .join, .apply:
                // **A surface with no opener offers nothing.** An inert Join
                // is exactly the control §5.5 forbids.
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
/// Capped, with the remainder counted — Discord's "+ N more", a chip like the
/// rest that opens them (`MoreTraitsChip`). A server may carry five and the
/// card is 320 points wide; three rows of chips would push the description off
/// the bottom of the thing they are meant to summarise.
private struct TraitFlow: View {
    var traits: [GuildTrait]

    private static let visible = 4

    var body: some View {
        FlowLayout(spacing: Spacing.tight) {
            ForEach(traits.prefix(Self.visible)) { GuildTraitChip(trait: $0) }
            if traits.count > Self.visible {
                MoreTraitsChip(traits: Array(traits.dropFirst(Self.visible)))
            }
        }
    }
}


// MARK: - The games a server plays

/// The row of game icons under a server's description.
///
/// **One game is named; several are a row of marks and a count.** Discord draws
/// exactly that split — a server with a single game shows its icon and its title
/// side by side, where five show five icons and a `+7` that opens the rest.
/// The reason is the row's job: with one game the name is the information, and
/// with twelve the icons are.
///
/// **The rest open in the card, not in a popover of their own.** This card is
/// itself a popover when a tag chip raised it, and the HIG's rule is one
/// popover at a time — so `+7` unfolds the list under the row, and the card
/// grows to hold it.
struct GuildProfileGameRow: View {
    @Environment(\.colorScheme) private var colorScheme
    var games: [GuildProfileGame]
    var open: ((ApplicationID) -> Void)?

    @Environment(\.motion) private var motion
    @State private var isShowingRest = false

    /// How many marks the row draws before the rest become a count. Five, which
    /// is what fits a 320-point card beside a `+N`.
    private static let inlineLimit = 5
    private static let side: CGFloat = 32

    var body: some View {
        if games.count == 1, let game = games.first {
            Button { open?(game.id) } label: {
                HStack(spacing: Spacing.snug) {
                    GuildProfileGameMark(game: game, side: Self.side)
                    Text(game.name)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(open == nil)
        } else {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                marks
                if isShowingRest {
                    GuildProfileGameList(
                        games: Array(games.dropFirst(Self.inlineLimit)),
                        open: { open?($0) }
                    )
                    .transition(.opacity)
                }
            }
            .animation(motion.standard, value: isShowingRest)
        }
    }

    private var marks: some View {
        HStack(spacing: Spacing.base) {
            ForEach(games.prefix(Self.inlineLimit)) { game in
                Button { open?(game.id) } label: {
                    GuildProfileGameMark(game: game, side: Self.side)
                }
                .buttonStyle(.plain)
                .disabled(open == nil)
                .help(game.name)
                .accessibilityLabel(Text(game.name))
            }
            if games.count > Self.inlineLimit, !isShowingRest {
                Button { isShowingRest = true } label: {
                    Text("+\(games.count - Self.inlineLimit)")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(InkColor.secondary)
                        .monospacedDigit()
                        .frame(width: Self.side, height: Self.side)
                        .background(
                            ProfileFlyoutGround.raised(in: colorScheme),
                            in: .rect(cornerRadius: 9, style: .continuous)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text("Show \(games.count - Self.inlineLimit) more games")
                )
            }
            Spacer(minLength: 0)
        }
    }
}

/// One game's icon, with the flame a busy one wears.
///
/// **The flame is cut OUT of the icon, not laid on it.** Discord notches the
/// icon's corner and sits the mark in the hole, so the two read as one object —
/// a flame painted on top would be a sticker on a picture. The notch is the same
/// even-odd mask the rail's live-voice tile uses and the mutual-avatar cluster
/// does: a circle subtracted from the icon's own shape.
private struct GuildProfileGameMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var game: GuildProfileGame
    var side: CGFloat

    /// The flame's own size, and how far its centre sits outside the icon's
    /// top-trailing corner.
    private var flameSide: CGFloat { side * 0.5 }
    /// The clearance bitten out around it, so the icon does not touch the mark.
    private var clearance: CGFloat { 1.5 }

    var body: some View {
        RemoteImage(url: game.iconURL, side: side) {
            ProfileFlyoutGround.raised(in: colorScheme)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.28, style: .continuous))
        .mask {
            if game.isHot {
                GameMarkNotch(flameSide: flameSide, clearance: clearance, corner: side * 0.28)
                    .fill(style: FillStyle(eoFill: true))
            } else {
                Rectangle()
            }
        }
        .overlay(alignment: .topTrailing) {
            if game.isHot {
                Text("🔥")
                    .font(.system(size: flameSide * 0.82))
                    .frame(width: flameSide, height: flameSide)
                    .offset(x: flameSide * 0.32, y: -flameSide * 0.32)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The icon's shape with a disc taken out of its top-trailing corner.
nonisolated private struct GameMarkNotch: Shape {
    var flameSide: CGFloat
    var clearance: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
        let centre = CGPoint(
            x: rect.maxX + flameSide * 0.32,
            y: rect.minY - flameSide * 0.32 + flameSide / 2
        )
        let radius = flameSide / 2 + clearance
        path.addEllipse(
            in: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        return path
    }
}

/// The games the row had no room for.
private struct GuildProfileGameList: View {
    var games: [GuildProfileGame]
    var open: (ApplicationID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(games) { game in
                Button { open(game.id) } label: {
                    HStack(spacing: Spacing.snug) {
                        GuildProfileGameMark(game: game, side: 26)
                        Text(game.name)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 36)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        // The card's own measure, so each mark lines up under the row's.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
