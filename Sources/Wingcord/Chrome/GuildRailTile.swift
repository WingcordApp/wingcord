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
    /// A right-click, with the tile's own frame in the window root's space.
    ///
    /// **The tile reports and stops.** §2 forbids a presentation modifier on a
    /// row, and this column can hold ninety-seven of them; the menu is hung off
    /// this rect at the window root — see `ServerOptionsPresenter`.
    var openMenu: (CGRect) -> Void = { _ in }

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
                // **The clip and the notch are one shape.** Cutting the corner
                // was a second mask over this until it took the whole tile with
                // it — see `NotchedRailTile`. The badges below are overlaid
                // after it and are not cut with it.
                .clipShape(
                    NotchedRailTile(
                        cornerRadius: cornerRadius,
                        isNotched: guild.voiceMark != nil
                    ),
                    style: FillStyle(eoFill: true)
                )
                .overlay(alignment: .bottomTrailing) {
                    if guild.mentionCount > 0 {
                        UnreadBadge(count: guild.mentionCount, isMuted: guild.isMuted)
                            .offset(x: 3, y: 3)
                    }
                }
                // **The opposite corner from the mention count**, because the
                // two say unrelated things and a tile can carry both: one is
                // about you, the other is about the room.
                .overlay(alignment: .topTrailing) {
                    if let mark = guild.voiceMark {
                        LiveVoiceMark(mark: mark, isConnected: guild.isConnectedToVoice)
                            .offset(x: RailMarkGeometry.inset.x, y: RailMarkGeometry.inset.y)
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
        .railHoverLabel(guild.name, guildID: guild.id, isHovered: isHovering)
        // One empty layer-less `NSView` per tile that reports a point — see
        // `SecondaryClickCatcher` for why this is not a `.contextMenu`.
        .onSecondaryClick { openMenu($0) }
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

/// Add a Server.
///
/// **Below the servers, not above them**, which is where Discord puts it and
/// where it belongs: the rail is read top-down as "where I am, then what I am
/// in", and an action tile among the memberships would be a button somebody
/// aims past on the way to a server they visit every day.
///
/// It borrows `HomeRailTile`'s geometry rather than `GuildRailTile`'s: it is not
/// a server, so it has no unread state, no selected state and no indicator —
/// only the hover morph every tile in the column shares, so the column still
/// reads as one row of controls.
struct AddServerRailTile: View {
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var side: CGFloat { Metrics.guildTile }

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: side * 0.36, weight: .medium))
                // Green on hover, like Discord's — the one place in the rail
                // where a colour means "this makes something new" rather than
                // "this is unread".
                .foregroundStyle(
                    isHovering ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.affirmative)
                )
                .frame(width: side, height: side)
                .background(isHovering ? Palette.affirmative : Palette.surfaceRaised)
                .clipShape(.rect(
                    cornerRadius: isHovering ? 17 : side / 2,
                    style: .continuous
                ))
                // The whole column is the target, exactly as the other tiles:
                // the rail is a strip of 44-point pictures and aiming between
                // them should not miss.
                .frame(width: Proportions.railWidth, height: side)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .railHoverLabel("Add a Server", isHovered: isHovering)
        .accessibilityLabel(Text("Add a Server"))
        .accessibilityAddTraits(.isButton)
    }
}

/// The compass, under the `+`.
///
/// **Its own tile rather than a row in the Add a Server sheet**, because it is a
/// destination and not an action: it takes the detail column and stays there
/// while somebody browses, where the sheet is a task with an end. Discord puts
/// it in the same place, and the shape is the rail's own — the `+` tile with a
/// different glyph and a different accent, so the two read as a pair of ways to
/// gain a server rather than as two unrelated controls.
struct DiscoverRailTile: View {
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var side: CGFloat { Metrics.guildTile }
    /// Lit while discovery is the column, hovered, or neither.
    private var isLit: Bool { isSelected || isHovering }

    var body: some View {
        Button(action: action) {
            Image(systemName: "safari")
                .font(.system(size: side * 0.42, weight: .medium))
                // **The accent, where the `+` above it is green.** The colour
                // is the difference between the two: green in this rail means
                // "this makes something new" — the comment on `AddServerRailTile`
                // says so — and discovery makes nothing. It is a destination, so
                // it takes the app's one accent, which is what every other
                // destination-shaped control here uses.
                .foregroundStyle(isLit ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.accent))
                .frame(width: side, height: side)
                .background(isLit ? Palette.accent : Palette.surfaceRaised)
                // The rail's own squircle-on-hover, which every tile in the
                // column shares: a circle at rest, a rounded square when it is
                // the thing being pointed at.
                .clipShape(.rect(
                    cornerRadius: isLit ? 17 : side / 2,
                    style: .continuous
                ))
                .frame(width: Proportions.railWidth, height: side)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isLit)
        .railHoverLabel("Discover", isHovered: isHovering)
        .accessibilityLabel(Text("Discover"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The mark on a rail tile that says what that server's rooms are doing — a
/// stage, a screen, a camera or a conversation, whichever ranks highest.
///
/// **The one thing on the rail that says a room is busy without being
/// hovered.** Everything else a tile carries is about the reader — an unread, a
/// mention; this is about the room, which is why it takes the opposite corner
/// rather than competing for the same one.
///
/// A filled plate rather than a bare glyph: the tile behind it is somebody's
/// artwork, and a monochrome symbol laid straight on it disappears against half
/// the servers on the rail.
struct LiveVoiceMark: View {
    var mark: RailVoiceMark
    /// Whether the reader is in a call in this server. **Green, as Discord
    /// draws it** (`isCurrentUserConnected`): the one mark on the rail that is
    /// about the reader rather than about the room.
    var isConnected = false

    var body: some View {
        Image(systemName: mark.symbolName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: RailMarkGeometry.side, height: RailMarkGeometry.side)
            .background {
                // **Discord's plate: a dark circle, not a light square.** Its
                // `iconBadge` (module `260727`, stylesheet `42809`) is a round
                // `--icon-overlay-dark` — black — and `--status-positive` while
                // the reader is in the call. A white plate over the artwork was
                // the loudest thing on the rail.
                Circle()
                    .fill(isConnected ? AnyShapeStyle(Palette.presenceOnline) : AnyShapeStyle(Color.black))
            }
            // It reports what is happening; the tile under it is the control.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Where the live mark sits on a tile, and what it clears around itself.
///
/// **One set of numbers, read by both halves.** The mark is a view and the hole
/// is a shape, and a shape in this module cannot reach a view's constants — the
/// app target is main-actor by default and a `Shape` conformance is not. Split
/// across the two, these would be a pair to keep in step, which is exactly the
/// defect a badge drawn in one place and cut in another produces.
///
/// **The mark is not laid on the icon, it is set INTO it** — Discord punches a
/// hole and this does the same. A plate dropped straight on somebody's
/// artwork reads as a sticker; the same plate with the rail showing through
/// around it reads as part of the tile.
///
/// Discord's numbers, scaled from its 48-point tile to this 44: a 20-point
/// circle 6 above the tile's top and 4 past its trailing edge.
nonisolated enum RailMarkGeometry {
    static let side: CGFloat = 18
    /// How far the mark hangs past the tile's own corner.
    static let inset = CGPoint(x: 4, y: -5)
    /// The ring of bare rail cleared around it.
    static let gap: CGFloat = 3
    /// What the notch takes out.
    static var cutSide: CGFloat { side + gap * 2 }

    /// Where the bite goes, in the tile's own space.
    static func notch(in rect: CGRect) -> CGRect {
        let centre = CGPoint(
            x: rect.maxX - side / 2 + inset.x,
            y: rect.minY + side / 2 + inset.y
        )
        return CGRect(
            x: centre.x - cutSide / 2,
            y: centre.y - cutSide / 2,
            width: cutSide,
            height: cutSide
        )
    }
}

/// A rail tile's silhouette: its rounded square, with a bite taken out of the
/// corner where the live mark sits.
///
/// **One shape with a hole in it, not a mask laid over the tile.** The mask this
/// replaces used `.destinationOut` inside a `.mask`, and it took the whole tile
/// with it: the notch hangs *past* the tile's corner by design, so the mask
/// view's own bounds grew larger than the thing it was masking, and a mask
/// bigger than its content is aligned against it rather than laid on it. The
/// icon vanished and only the badge was left.
///
/// Even-odd filling has none of that. A rect containing an ellipse fills to a
/// rect with a hole in it, the shape's bounds are the tile's, and it replaces
/// the clip the tile already had rather than adding an offscreen pass to it.
///
/// **A hole rather than a ring in the rail's colour**, because behind this
/// column is the wallpaper: a painted ring is only right for as long as whatever
/// is back there happens to be the colour it was painted.
nonisolated struct NotchedRailTile: Shape {
    var cornerRadius: CGFloat
    /// Whether the corner is cut at all. Nothing else about the shape changes.
    var isNotched: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(
            roundedRect: rect, cornerRadius: cornerRadius, style: .continuous
        )
        // The second subpath is what the even-odd rule subtracts. Drawn even
        // where it falls outside the tile: the parts of it that do simply have
        // nothing to take away.
        if isNotched { path.addEllipse(in: RailMarkGeometry.notch(in: rect)) }
        return path
    }
}
