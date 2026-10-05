import SwiftUI
import WingcordCore

/// One board tile.
///
/// **Three shapes, and which one is drawn is a fact about the tile.** A widget
/// naming a single game is a hero card — cover, title, the comment they wrote
/// and their tags; a widget naming several is a shelf of artwork under a
/// heading; an application's own widget carries hero art and a stat grid and
/// takes the bleeding slab. The handoff draws all three and they are not
/// variants of one card.
struct BoardSlab: View {
    var tile: BoardTile
    var ground: ProfileGround
    var userID: UserID

    @State private var isMenuOpen = false

    var body: some View {
        BoardSlabBody(tile: tile, ground: ground) {
            AnyView(
                BoardTileMenuButton(
                    isOpen: $isMenuOpen,
                    widgetID: tile.id,
                    userID: userID,
                    gameID: tile.linkedGameID
                )
            )
        }
    }
}

/// The same tile with nothing to press, for the report sheet.
struct BoardTilePreview: View {
    var tile: BoardTile

    var body: some View {
        // The app's own neutral ground. See `ReportSheet.preview`: this sheet is
        // the app asking a question, and the reported account's theme has no
        // business framing it.
        BoardSlabBody(tile: tile, ground: ProfileGround(themeColorValues: []))
            .allowsHitTesting(false)
    }
}

/// A tile's surface and content.
private struct BoardSlabBody: View {
    var tile: BoardTile
    var ground: ProfileGround
    /// The "…". Nil in the report sheet's preview, where nothing is pressable.
    var menu: (() -> AnyView)?

    var body: some View {
        switch tile.content {
        case .application(let application):
            ProfileBleedSlab(ground: ground) {
                ApplicationWidgetCard(tile: application, ground: ground)
            }
            .overlay(alignment: .topTrailing) { menu?().padding(Spacing.snug) }
        case .detailed(let games):
            if let only = games.first, games.count == 1 {
                FeaturedGameCard(title: tile.title, game: only, ground: ground, menu: menu)
            } else {
                GameShelf(title: tile.title, games: games, ground: ground, menu: menu)
            }
        case .grid(let games):
            GameShelf(title: tile.title, games: games, ground: ground, menu: menu)
        case .personal(let widget):
            ProfileBleedSlab(ground: ground) {
                PersonalWidgetCard(widget: widget, ground: ground)
            }
            .overlay(alignment: .topTrailing) { menu?().padding(Spacing.snug) }
        }
    }
}

/// The hero card: one game, at the size the handoff draws it.
///
/// **The bleed is the point.** The card's ground is a blurred radial wash at its
/// leading edge, behind the glass and under the cover — which is what makes it
/// read as a card *about* something rather than a rectangle with a picture in the
/// corner. The handoff pulls that colour out of the box art; this pulls it from
/// the person's own ground, which is the source `INVARIANTS.md` §4 already
/// mandates and costs no second decode per game.
private struct FeaturedGameCard: View {
    var title: String
    var game: BoardGame
    var ground: ProfileGround
    var menu: (() -> AnyView)?

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let cover: CGFloat = 80
    private static let corner: CGFloat = 22

    var body: some View {
        Button { model.openGameProfile(game.gameID) } label: { card }
            .buttonStyle(.plain)
            .disabled(game.name == nil)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            // The handoff's lift: three points up and a deeper shadow, which is
            // the whole hover state. Nothing changes colour — the card is
            // already the person's colour.
            .offset(y: isHovering ? -3 : 0)
            .shadow(
                color: .black.opacity(isHovering ? 0.5 : 0.34),
                radius: isHovering ? 30 : 20,
                y: isHovering ? 14 : 9
            )
            .animation(motion.hover, value: isHovering)
            .accessibilityHint(Text("Opens the game's profile"))
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 15) {
            GameCover(game: game, width: Self.cover, corner: 16)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Spacing.base) {
                    Text(title)
                        .font(Typeface.sectionHeader)
                        .foregroundStyle(InkColor.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.9)
                    Spacer(minLength: 0)
                    menu?()
                }
                Text(game.name ?? " ")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                    // Redacted rather than blank while `/games` is out: the card
                    // keeps its height, so nothing reflows when the name lands.
                    .redacted(reason: game.name == nil ? .placeholder : [])
                if let comment = game.comment {
                    // **Quoted, because it is theirs.** A comment set in plain
                    // body text beside a title reads as a subtitle the app
                    // wrote; the marks say a person did.
                    Text("\u{201C}\(comment)\u{201D}")
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(2)
                }
                if !game.tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(Array(game.tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                            GameTagChip(tag: tag)
                        }
                        if game.tags.count > 3 {
                            GameTagOverflowChip(count: game.tags.count - 3)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) { bleed }
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Self.corner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
        }
        .contentShape(.rect(cornerRadius: Self.corner, style: .continuous))
    }

    /// The wash behind the cover. Blurred well past any edge, so what reaches
    /// the glass is light rather than a shape.
    @ViewBuilder
    private var bleed: some View {
        if let accent = ground.accent {
            Circle()
                .fill(accent.opacity(0.55))
                .frame(width: 190, height: 190)
                .blur(radius: 46)
                .offset(x: -40)
                .allowsHitTesting(false)
        }
    }
}

/// Several games under one heading, as a shelf of artwork.
///
/// **The heading sits outside the tiles, not inside a card around them.** That
/// is the handoff's arrangement and it is the right one: a wall of box art is
/// already a group, and drawing a second box around it is a container with
/// nothing to contain.
private struct GameShelf: View {
    var title: String
    var games: [BoardGame]
    var ground: ProfileGround
    var menu: (() -> AnyView)?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(InkColor.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.9)
                Spacer(minLength: 0)
                menu?()
            }
            .padding(.horizontal, Spacing.tight)

            FlowLayout(spacing: 10) {
                ForEach(games) { game in
                    ShelfTile(game: game, ground: ground)
                }
            }
        }
    }
}

/// One game on a shelf: its art, its name over the foot of it, its tags under.
private struct ShelfTile: View {
    var game: BoardGame
    var ground: ProfileGround

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let width: CGFloat = GameArt.shelfWidth
    private static let corner: CGFloat = 18

    var body: some View {
        Button { model.openGameProfile(game.gameID) } label: { tile }
            .buttonStyle(.plain)
            .disabled(game.name == nil)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .offset(y: isHovering ? -4 : 0)
            .scaleEffect(isHovering ? 1.015 : 1)
            .shadow(
                color: .black.opacity(isHovering ? 0.55 : 0.4),
                radius: isHovering ? 26 : 18,
                y: isHovering ? 12 : 8
            )
            .animation(motion.hover, value: isHovering)
            .help(game.name ?? "")
            .accessibilityLabel(Text(game.name ?? "Game"))
            .accessibilityHint(Text("Opens the game's profile"))
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            GameCover(game: game, width: Self.width, corner: Self.corner)
                // The name rides the foot of the artwork under a scrim, which is
                // what the handoff does and what keeps a shelf reading as a
                // shelf rather than as a grid of pictures with captions.
                .overlay(alignment: .bottom) { nameplate }
                .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
            if !game.tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(Array(game.tags.prefix(2).enumerated()), id: \.offset) { _, tag in
                        GameTagChip(tag: tag)
                    }
                }
                .frame(width: Self.width, alignment: .leading)
            }
        }
        .contentShape(.rect)
    }

    private var nameplate: some View {
        Text(game.name ?? " ")
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .redacted(reason: game.name == nil ? .placeholder : [])
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
            .padding(.top, 26)
            .background {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }
}

/// One game's box art.
///
/// **A portrait frame, always.** Box art is 3:4 and a shelf of games only reads
/// as a shelf when every spine is the same shape — which is the whole reason
/// this stopped being a square. `width` sets the frame; the height follows from
/// `GameArt.coverAspect`, so no call site can put a game in a box of its own
/// proportions.
struct GameCover: View {
    var game: BoardGame
    /// The frame's width. Nil takes whatever the layout offers, which is what a
    /// grid column needs.
    var width: CGFloat?
    /// The frame's radius. Nil scales it with the width, which is right
    /// everywhere the cover stands alone; the shelf and the hero card set it
    /// because their corner has to match the tile the cover sits in.
    var corner: CGFloat?

    private static let cornerFraction: CGFloat = 0.11

    private var referenceWidth: CGFloat { width ?? GameArt.gridWidth }
    private var resolvedCorner: CGFloat { corner ?? referenceWidth * Self.cornerFraction }

    var body: some View {
        Group {
            if let width {
                art.frame(width: width, height: width / GameArt.coverAspect)
            } else {
                art.aspectRatio(GameArt.coverAspect, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: resolvedCorner, style: .continuous))
        // A hairline over the artwork rather than under it: many covers are
        // near-black at the edge and would otherwise bleed into the slab.
        .overlay {
            RoundedRectangle(cornerRadius: resolvedCorner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .accessibilityLabel(Text(game.name ?? "Game"))
    }

    /// The picture, and what to do when it is the wrong shape.
    @ViewBuilder
    private var art: some View {
        if game.coverURL == nil {
            plate
        } else if game.isCoverArt {
            // Real box art fills the frame. Cropped rather than letterboxed —
            // IGDB's covers vary a little either side of 3:4 and a black bar is
            // worse than two lost pixels.
            image(side: referenceWidth * 2).aspectRatio(contentMode: .fill)
        } else {
            // **A square icon standing in for a cover.** Centred at 62% on a
            // blurred, brightened copy of itself, which is how a store makes a
            // poster out of a logo. Stretching it is what made Hytale's shield
            // and the Sims plumbob read as blurry upscales.
            ZStack {
                image(side: 96)
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: referenceWidth * 0.16, opaque: true)
                    .saturation(1.5)
                    .overlay(Color.black.opacity(0.15))
                image(side: referenceWidth * 2)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: referenceWidth * 0.62)
                    .clipShape(.rect(cornerRadius: referenceWidth * 0.14, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: referenceWidth * 0.08, y: 2)
            }
        }
    }

    private func image(side: CGFloat) -> some View {
        RemoteImage(url: game.coverURL, side: side, bucket: .artwork) { plate }
    }

    /// What a game wears before its art lands, and forever if it has none.
    ///
    /// A symbol rather than a monogram: a cover is a picture, and two letters in
    /// a box reads as an avatar.
    private var plate: some View {
        ZStack {
            Palette.surfaceRaised
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: referenceWidth * 0.26))
                .foregroundStyle(InkColor.tertiary)
        }
    }
}

/// A game's square mark.
///
/// The other half of `GameArtKind`: at thirty points box art is a smudge and the
/// app icon is what a reader recognises. Squircle rather than circle — measured
/// against Discord's own strip, where Battlefield keeps its square and The Sims
/// only *looks* round because its artwork is a white disc.
struct GameMark: View {
    var game: BoardGame
    var side: CGFloat

    private var corner: CGFloat { side * 0.24 }

    var body: some View {
        RemoteImage(url: game.coverURL, side: side * 2, bucket: .artwork) {
            ZStack {
                Palette.surfaceRaised
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(InkColor.tertiary)
            }
        }
        .aspectRatio(contentMode: .fill)
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .accessibilityLabel(Text(game.name ?? "Game"))
    }
}

/// One badge under a game — "Expert", "Love It", "Looking for Group".
struct GameTagChip: View {
    var tag: GameWidgetTag

    var body: some View {
        HStack(spacing: 4) {
            Image(symbol: tag.symbolName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(InkColor.tertiary)
            Text(tag.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // A capsule, and clear glass — matching the role chips one column over.
        // These are the same object, a small factual badge on somebody's own
        // ground, and giving them two shapes is what makes a profile look
        // assembled from parts.
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// The tags a capped row could not show.
///
/// **A count, not a `+n` that opens something.** The full set is on the game's
/// own profile, which the tile already opens; a second control inside the first
/// would be two targets in the same eleven points.
struct GameTagOverflowChip: View {
    var count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(InkColor.tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.clear, in: .capsule)
            .accessibilityLabel(Text("\(count) more"))
    }
}
