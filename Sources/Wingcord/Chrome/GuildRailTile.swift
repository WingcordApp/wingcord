import SwiftUI
import WingcordCore

/// One server in the rail.
///
/// Selection morphs the tile from a squircle toward a rounded rect and grows a
/// pill on the leading edge. **The pill is also the unread mark**, at a shorter
/// length — one element carrying both states rather than two marks competing for
/// the same eight points of gutter.
///
/// The corner radius animates; the shape does not swap. Swapping
/// `Circle()`/`RoundedRectangle()` gives the tile two view identities, so a
/// selection change rebuilds instead of morphing and the transition cuts.
struct GuildRailTile: View {
    var guild: RailGuild
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    /// Whether the animated layer has frames on screen. Drives the still's
    /// hand-off, so there is never both and never neither.
    @State private var isPlaying = false

    private var side: CGFloat { Metrics.guildTile }

    /// Squircle at rest, rounded rect when selected or under the pointer.
    private var cornerRadius: CGFloat {
        isSelected ? 14 : (isHovering ? 17 : side / 2)
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RailIndicator(isSelected: isSelected, hasUnread: guild.hasUnread)

                RemoteImage(url: guild.iconURL, side: side) {
                    Text(guild.monogram)
                        .font(.system(size: side * 0.30, weight: .bold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: side, height: side)
                        .background(Palette.surfaceRaised)
                }
                // **Hidden once the filmstrip is up.** The still is the GIF's
                // own first frame, but the two are decoded by different paths at
                // different sizes and an animated icon is authored with a soft
                // or transparent rim — so the still showed as a second, slightly
                // larger copy sitting behind the moving one. It is only there to
                // cover the moment before the film lands, so it goes when the
                // film arrives and comes back when the pointer leaves.
                .opacity(isPlaying ? 0 : 1)
                .frame(width: side, height: side)
                // **Animated icons play under the pointer and nowhere else.**
                //
                // A rail of ninety-seven servers is, on a well-decorated
                // account, dozens of animated icons — dozens of filmstrips
                // resident and dozens of layers being written every clock tick,
                // for a column nobody is looking at while they read. Hovering is
                // the moment someone is actually looking at one, so that is when
                // it plays: the view exists only while `isHovering` is true, and
                // `AnimatedDecoration` subscribes to the clock on appear and
                // unsubscribes on disappear, so a rail at rest costs nothing at
                // all.
                //
                // The still underneath is the GIF's own first frame — the icon
                // URL is already the animated rendition — so there is nothing to
                // cross-fade to on the way in, and the way out is a cut back to
                // frame zero rather than a dissolve between two unrelated
                // frames.
                .overlay {
                    if isHovering, let url = guild.iconURL, CDN.canAnimate(url) {
                        AnimatedDecoration(
                            url: url,
                            side: side,
                            gravity: .resizeAspectFill,
                            onPlayback: { playing in
                                guard isPlaying != playing else { return }
                                isPlaying = playing
                            }
                        )
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if guild.mentionCount > 0 {
                        UnreadBadge(count: guild.mentionCount, isMuted: guild.isMuted)
                            .offset(x: 3, y: 3)
                    }
                }
                .opacity(guild.isMuted && !isSelected ? 0.55 : 1)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // **The hit region is declared, never inferred from what is
            // visible.** The still underneath is taken to zero opacity the
            // moment the filmstrip has frames, and the filmstrip itself refuses
            // hits — so on an animated icon the button's only remaining
            // hit-testable content was the four-point indicator capsule at the
            // leading edge. The tile looked pressable and swallowed every click
            // until the animation happened not to be running, which is exactly
            // "I have to hover twice before a server opens".
            //
            // Declared on the LABEL rather than outside the button: a
            // `.contentShape` outside a `Button` describes the button's own
            // frame, and it is the label that decides what a plain-styled
            // button hit-tests.
            .frame(width: Proportions.railWidth, height: side)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The guard is on the MODIFIER, not inside the closure. `.onHover`
        // compiles to an AppKit tracking area whose geometry is re-derived
        // whenever its visible rect moves — every frame of every scroll —
        // so installing one and returning early inside still pays for it.
        .onHover { hovering in
            // A `@State` write of an equal value still invalidates.
            guard isHovering != hovering else { return }
            isHovering = hovering
            // The animated layer leaves the tree with the hover, and it cannot
            // report that it has stopped once it is gone.
            if !hovering { isPlaying = false }
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.glassMorph, value: isSelected)
        // **A published anchor, not a popover.** A rail tile is a wordless
        // 44-point picture, so its name is the only thing that identifies it —
        // and it has to arrive while the reader is still asking. One chip is
        // drawn for the whole rail and travels between tiles; see
        // `RailHoverLabel`.
        .railHoverLabel(guild.name, isHovered: isHovering)
        .accessibilityLabel(Text(guild.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The home entry: direct messages.
struct HomeRailTile: View {
    var isSelected: Bool
    var mentionCount: Int
    var hasUnread: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var side: CGFloat { Metrics.guildTile }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RailIndicator(isSelected: isSelected, hasUnread: hasUnread)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: side * 0.38))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.secondary))
                    .frame(width: side, height: side)
                    .background(Palette.surfaceRaised)
                    .clipShape(.rect(
                        cornerRadius: isSelected ? 14 : (isHovering ? 17 : side / 2),
                        style: .continuous
                    ))
                    .overlay(alignment: .bottomTrailing) {
                        if mentionCount > 0 {
                            UnreadBadge(count: mentionCount, isMuted: false)
                                .offset(x: 3, y: 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // The whole column is the target, for the reason above: the rail is
            // a strip of 44-point pictures and aiming between them should not
            // miss.
            .frame(width: Proportions.railWidth, height: side)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.glassMorph, value: isSelected)
        .railHoverLabel("Direct Messages", isHovered: isHovering)
        .accessibilityLabel(Text("Direct Messages"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One element, three lengths: absent, a short unread pip, or a tall selected
/// pill.
///
/// Selected is deliberately much taller *and* wider than the unread pip. At the
/// same width it reads as a slightly longer pip rather than as a different
/// state, and selection becomes ambiguous at a glance.
struct RailIndicator: View {
    var isSelected: Bool
    var hasUnread: Bool

    @Environment(\.motion) private var motion

    var body: some View {
        Capsule()
            .fill(Ink.primary)
            .frame(
                width: isSelected ? 5 : 4,
                height: isSelected ? Metrics.guildTile * 0.8 : (hasUnread ? 9 : 0)
            )
            // Flush to the leading edge, never past it: a negative offset puts
            // half the pip outside the column, where the clip eats it.
            .padding(.leading, 3)
            .animation(motion.standard, value: isSelected)
            .animation(motion.standard, value: hasUnread)
            .accessibilityHidden(true)
    }
}

/// An unread count.
///
/// Monospaced digits so the badge does not jitter in width as the count ticks,
/// and a cap so a thousand-message backlog does not widen a 44pt tile.
struct UnreadBadge: View {
    var count: Int
    var isMuted: Bool

    private var label: String { count > 99 ? "99+" : String(count) }

    var body: some View {
        Text(label)
            .font(Typeface.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 4 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background {
                Capsule().fill(isMuted ? Palette.mutedBadge : Palette.unreadBadge)
            }
            .overlay {
                // Separates the badge from whatever it overlaps. A ring in the
                // window's own background colour rather than a material —
                // material over artwork reads as a blur smudge.
                Capsule()
                    .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
            }
            .accessibilityLabel(Text("^[\(count) unread message](inflect: true)"))
    }
}
