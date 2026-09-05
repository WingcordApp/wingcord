import SwiftUI
import WingcordCore

/// One board tile, as a slab on the profile stage.
///
/// **Glass over the ambient field, not a flat wash.** These used to be
/// `panelFill` — a sixteen-per-cent tint — because the surface behind them was
/// paint and there was nothing to refract. On the stage there is, so they take
/// the same clear glass every other slab does and lens the person's own banner.
struct BoardSlab: View {
    var tile: BoardTile
    var ground: ProfileGround
    var userID: UserID

    @State private var isMenuOpen = false

    var body: some View {
        Group {
            switch tile.content {
            case .application(let application):
                // The application widget carries its own header inside artwork
                // that runs to the tile's edges, so it takes the bleeding slab.
                ProfileBleedSlab(ground: ground) {
                    ApplicationWidgetCard(tile: application, ground: ground)
                }
            case .detailed(let games):
                ProfileSlab(title: tile.title, ground: ground) {
                    VStack(alignment: .leading, spacing: Spacing.snug) {
                        ForEach(games) { game in
                            DetailedGameRow(game: game)
                        }
                    }
                }
            case .grid(let games):
                ProfileSlab(title: tile.title, ground: ground) {
                    GameCoverWall(games: games)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            BoardTileMenuButton(
                isOpen: $isMenuOpen,
                widgetID: tile.id,
                userID: userID,
                gameID: tile.linkedGameID
            )
            .padding(Spacing.snug)
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

/// A tile's surface and content with no control on it.
private struct BoardSlabBody: View {
    var tile: BoardTile
    var ground: ProfileGround

    var body: some View {
        switch tile.content {
        case .application(let application):
            ProfileBleedSlab(ground: ground) {
                ApplicationWidgetCard(tile: application, ground: ground)
            }
        case .detailed(let games):
            ProfileSlab(title: tile.title, ground: ground) {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    ForEach(games) { game in
                        DetailedGameRow(game: game)
                    }
                }
            }
        case .grid(let games):
            ProfileSlab(title: tile.title, ground: ground) {
                GameCoverWall(games: games)
            }
        }
    }
}

/// A game with its comment and badges — the favourite and rotation tiles.
private struct DetailedGameRow: View {
    var game: BoardGame

    private static let coverWidth: CGFloat = GameArt.rowWidth

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            GameCover(game: game, width: Self.coverWidth)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name ?? " ")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(2)
                    // Redacted rather than blank while `/games` is out: the row
                    // keeps its height, so the card does not grow under the
                    // reader when the names land.
                    .redacted(reason: game.name == nil ? .placeholder : [])
                if let comment = game.comment {
                    // **Quoted, because it is theirs.** A comment set in plain
                    // body text beside a title reads as a subtitle the app
                    // wrote; the mark says a person did.
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 9))
                            .foregroundStyle(InkColor.tertiary)
                            .padding(.top, 3)
                        Text(comment)
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !game.tags.isEmpty {
                    FlowLayout(spacing: Spacing.tight) {
                        ForEach(Array(game.tags.enumerated()), id: \.offset) { _, tag in
                            GameTagChip(tag: tag)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.tight)
        .contentShape(.rect)
        .modifier(OpensGameProfile(gameID: game.gameID, isEnabled: game.name != nil))
    }
}

/// Covers only — the liked and wishlist tiles.
///
/// **A wrapping flow, not a fixed column count.** These slabs no longer have a
/// width this file knows: the masonry decides it, and it differs between a
/// one-column window and a three-column one. A flow puts as many covers on a row
/// as fit and wraps, which is the only arrangement that is right at both.
private struct GameCoverWall: View {
    var games: [BoardGame]

    var body: some View {
        FlowLayout(spacing: Spacing.base) {
            ForEach(games) { game in
                GameCover(game: game, width: GameArt.gridWidth)
                    .modifier(
                        OpensGameProfile(gameID: game.gameID, isEnabled: game.name != nil)
                    )
                    .help(game.name ?? "")
            }
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

    private static let cornerFraction: CGFloat = 0.11

    private var referenceWidth: CGFloat { width ?? GameArt.gridWidth }
    private var corner: CGFloat { referenceWidth * Self.cornerFraction }

    var body: some View {
        Group {
            if let width {
                art.frame(width: width, height: width / GameArt.coverAspect)
            } else {
                art.aspectRatio(GameArt.coverAspect, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        // A hairline over the artwork rather than under it: many covers are
        // near-black at the edge and would otherwise bleed into the slab.
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
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

/// A game's square mark, for the strip on the small card.
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
            Image(systemName: tag.symbolName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(InkColor.tertiary)
            Text(tag.title)
                .font(.system(size: 10))
                .foregroundStyle(InkColor.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        // Clear glass, matching the connection chips one column over: these are
        // the same object — a small factual badge on somebody's own ground —
        // and giving them two materials is what makes a profile look assembled
        // from parts.
        .glassEffect(.clear, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Makes a cover open the game's own profile.
///
/// A modifier rather than a `Button` at each site, because the two call sites
/// disagree about their shape and agree about everything else — and because a
/// game whose name has not arrived must not be clickable: the sheet it would
/// open has nothing to draw yet.
private struct OpensGameProfile: ViewModifier {
    var gameID: ApplicationID
    var isEnabled: Bool

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        Button { model.openGameProfile(gameID) } label: { content }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityHint(Text("Opens the game's profile"))
    }
}
