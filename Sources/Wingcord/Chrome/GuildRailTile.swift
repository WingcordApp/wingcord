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
                .frame(width: side, height: side)
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
        }
        .buttonStyle(.plain)
        .frame(width: Proportions.railWidth, height: side)
        // The guard is on the MODIFIER, not inside the closure. `.onHover`
        // compiles to an AppKit tracking area whose geometry is re-derived
        // whenever its visible rect moves — every frame of every scroll —
        // so installing one and returning early inside still pays for it.
        .onHover { hovering in
            // A `@State` write of an equal value still invalidates.
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.glassMorph, value: isSelected)
        .help(guild.name)
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
        }
        .buttonStyle(.plain)
        .frame(width: Proportions.railWidth, height: side)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.glassMorph, value: isSelected)
        .help("Direct Messages")
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
