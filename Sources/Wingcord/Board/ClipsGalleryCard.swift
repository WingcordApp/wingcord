import SwiftUI
import WingcordCore

// MARK: - Clips on a board
//
// docs/CLIPS-PRESENCE.md, Phase 7 (D18). Discord's clips gallery (`W` and `K`
// in build 643186): the first clip large, the rest in a row under it, each a
// picture with a play mark and its title; a press plays them in the viewer,
// one after another from the one pressed. On the popout, "Clips Gallery" over
// its pictures, and the card opens the board.

/// The board's tile.
///
/// **On the panel every other card on a profile has.** Discord wraps each of its
/// widgets, this one included, in the same container (`.container__62dd3`:
/// `--user-profile-overlay-background`, a 1px edge, `--radius-lg`), and this tile
/// was the one that had been left floating on the ground (Alex's image 54).
struct ClipsGalleryCard: View {
    var title: String
    var clips: [BoardClip]
    var ground: ProfileGround
    var userID: UserID
    var menu: (() -> AnyView)?

    @Environment(AppModel.self) private var model

    var body: some View {
        ProfileSlab(ground: ground) {
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

                // **Each at its own height, not a share of the card's.** Both are
                // flexible as far as this stack can tell, the row through the
                // fillers below, so it split what it had between them: the large
                // clip came out short and the row sat in a gap. Pinned, they're
                // the width they're given and 16:9 of it.
                if let first = clips.first {
                    ClipTile(clip: first, isLarge: true) { play(0) }
                        .fixedSize(horizontal: false, vertical: true)
                }
                if clips.count > 1 {
                    HStack(spacing: Spacing.base) {
                        ForEach(Array(clips.dropFirst().enumerated()), id: \.element.id) { offset, clip in
                            ClipTile(clip: clip, isLarge: false) { play(offset + 1) }
                        }
                        // A short row keeps its tiles at a third of the width
                        // rather than stretching two across the whole card.
                        ForEach(0 ..< max(0, 3 - (clips.count - 1)), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func play(_ index: Int) {
        let owner = model.users[userID]?.preferredName ?? "Clips Gallery"
        model.playBoardClips(clips, from: index, owner: owner)
    }
}

/// One clip: its picture, a play mark, and its title over the foot of it.
private struct ClipTile: View {
    var clip: BoardClip
    var isLarge: Bool
    var play: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    /// Discord's `--radius-md`, on the large one.
    private var corner: CGFloat { isLarge ? 12 : Radius.row }

    var body: some View {
        Button(action: play) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { face }
                .clipShape(.rect(cornerRadius: corner, style: .continuous))
                .contentShape(.rect(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .scaleEffect(isHovering ? 1.01 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.45 : 0.3), radius: isHovering ? 18 : 12, y: 6)
        .animation(motion.hover, value: isHovering)
        .help(clip.title ?? "Play clip")
        .accessibilityLabel(Text(clip.title ?? "Clip"))
        .accessibilityHint(Text("Plays the clip"))
    }

    private var face: some View {
        ZStack(alignment: .bottomLeading) {
            // **The picture in an overlay, never a sibling.** An aspect-filled
            // image reports its own size to layout, so any thumbnail that isn't
            // 16:9 would grow this stack past the tile and push the title out of
            // the clip. `GuildProfileCard` records the same trap.
            Rectangle()
                .fill(Palette.skeletonPlate)
                .overlay {
                    if let url = clip.thumbnailURL {
                        RemoteImage(url: url, side: isLarge ? 640 : 240, bucket: .thumbnail) { Color.clear }
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .clipped()
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                if let title = clip.title {
                    Text(title)
                        .font(.system(isLarge ? .subheadline : .caption, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if isLarge, let game = clip.gameName {
                    Text(game)
                        .font(.system(.caption))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(isLarge ? Spacing.snug : Spacing.tight)
            Image(systemName: "play.fill")
                .font(.system(size: isLarge ? 18 : 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(isLarge ? 14 : 8)
                .background(.black.opacity(0.45), in: .circle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(isHovering || isLarge ? 1 : 0.85)
        }
    }
}

/// The popout's card: "Clips Gallery", its pictures, and the board behind it.
struct ClipsGalleryPreview: View {
    var clips: [BoardClip]
    var ground: ProfileGround
    var open: () -> Void

    var body: some View {
        ProfilePanelButton(ground: ground, action: open) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.tight) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(InkColor.secondary)
                    Text("Clips Gallery")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(InkColor.primary)
                    // One clip names itself, as Discord's card does.
                    if clips.count == 1, let title = clips.first?.title {
                        Text(title)
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if clips.count > 1 {
                        Text("View all")
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(InkColor.secondary)
                    }
                }
                HStack(spacing: Spacing.tight) {
                    ForEach(clips.prefix(3)) { clip in
                        ZStack {
                            Rectangle().fill(Palette.skeletonPlate)
                            if let url = clip.thumbnailURL {
                                RemoteImage(url: url, side: 160, bucket: .thumbnail) { Color.clear }
                                    .aspectRatio(contentMode: .fill)
                            }
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.45), in: .circle)
                        }
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 4, style: .continuous))
                    }
                }
            }
            .padding(Spacing.base)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(Text("Clips Gallery, \(clips.count) clips"))
        .accessibilityHint(Text("Opens their board"))
    }
}
