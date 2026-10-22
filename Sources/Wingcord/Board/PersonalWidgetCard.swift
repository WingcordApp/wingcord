import SwiftUI
import WingcordCore

/// A widget the reader wrote, as the board draws it.
///
/// **A cover and a two-by-two grid, and both halves are optional.** Discord's
/// editor offers four slots and fills none of them by default, so a widget with
/// a cover and no fields is an ordinary state rather than a half-built one — and
/// a grid drawn for four empty slots is four empty boxes.
struct PersonalWidgetCard: View {
    var widget: PersonalWidget
    var ground: ProfileGround

    private static let coverHeight: CGFloat = 128
    private static let fieldSide: CGFloat = 44

    /// A slot with no title, no description and no picture was never filled in.
    private var filledFields: [PersonalWidget.Field] {
        widget.fields.filter {
            !$0.title.isEmpty || !$0.description.isEmpty || $0.image != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            cover
            if !filledFields.isEmpty {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: Spacing.snug),
                        count: 2
                    ),
                    spacing: Spacing.snug
                ) {
                    ForEach(filledFields) { field in
                        fieldRow(field)
                    }
                }
            }
        }
        .padding(Spacing.snug)
    }

    /// The banner, with the title and its line sitting over the foot of it.
    ///
    /// **The words go over the picture, not under it**, which is what the
    /// captured card does — and the scrim is what keeps them readable over
    /// artwork nobody here chose.
    private var cover: some View {
        Color.clear
            .frame(height: Self.coverHeight)
            .background {
                if let image = widget.cover.image {
                    PersonalAssetImage(asset: image, side: 512)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Palette.skeletonPlate)
                }
            }
            .overlay {
                if !widget.cover.title.isEmpty || !widget.cover.subtitle.isEmpty {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    if !widget.cover.title.isEmpty {
                        Text(widget.cover.title)
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if !widget.cover.subtitle.isEmpty {
                        Text(widget.cover.subtitle)
                            .font(.system(.subheadline))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(Spacing.snug)
            }
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
    }

    private func fieldRow(_ field: PersonalWidget.Field) -> some View {
        HStack(spacing: Spacing.base) {
            Group {
                if let image = field.image {
                    PersonalAssetImage(asset: image, side: Self.fieldSide * 2)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Palette.skeletonPlate)
                }
            }
            .frame(width: Self.fieldSide, height: Self.fieldSide)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(field.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                if !field.description.isEmpty {
                    Text(field.description)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One picture from a personal widget.
///
/// **Drawn from Discord's widget-assets address**, which is keyed by the
/// widget's owner (`CDN.widgetAsset`) — the reason it could not be drawn
/// before: the owner was not known down here. It now rides the environment
/// (`widgetOwner`), set wherever a board or a popout is drawn for somebody.
/// A moving picture plays under the pointer, as Discord's does, and holds its
/// first frame otherwise.
///
/// A picture the reader has *just* chosen is still bytes in the editor and
/// draws from there.
struct PersonalAssetImage: View {
    var asset: PersonalWidget.Asset
    var side: CGFloat

    @Environment(\.widgetOwner) private var owner
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    /// Whether the moving picture is up, so the still under it can go — the
    /// same latch `AvatarView` keeps for a moving face.
    @State private var filmIsPlaying = false

    var body: some View {
        Rectangle()
            .fill(Palette.skeletonPlate)
            .overlay {
                if let still {
                    RemoteImage(url: still, side: side, bucket: .thumbnail) { placeholder }
                        .aspectRatio(contentMode: .fill)
                        .opacity(filmIsPlaying && plays ? 0 : 1)
                } else {
                    placeholder
                }
            }
            .overlay {
                // **A moving picture plays**, which it never did: the still was
                // all this drew. Discord's rule (build 643186, `326009`'s `C`):
                // always with GIF autoplay on, under the pointer with it off,
                // and a GIF tag on it while it is still.
                if plays, let moving {
                    AnimatedDecoration(
                        url: moving,
                        side: side,
                        gravity: .resizeAspectFill,
                        onPlayback: { playing in
                            guard filmIsPlaying != playing else { return }
                            filmIsPlaying = playing
                        }
                    )
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isAnimated, !plays {
                    Text("GIF")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .rect(cornerRadius: 4, style: .continuous))
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .onChange(of: plays) { _, playing in if !playing { filmIsPlaying = false } }
            .accessibilityLabel(Text(isAnimated ? "Moving picture" : "Picture"))
    }

    private var isAnimated: Bool {
        if case .stored(_, _, _, let animated) = asset { animated } else { false }
    }

    /// Whether the moving form is on screen: an animated picture, with
    /// autoplay on or the pointer over it — and never against Reduce Motion
    /// or Game Mode's throttle, as with every other moving thing here.
    private var plays: Bool {
        isAnimated
            && (AppSettings.shared.playsAnimatedContent || isHovering)
            && !motion.reduceMotion
            && !GameMode.shared.isThrottling
    }

    private var still: URL? {
        guard let owner, case .stored(let fileID, _, _, _) = asset else { return nil }
        return CDN.widgetAsset(owner: owner, fileID: fileID, animated: false)
    }

    private var moving: URL? {
        guard let owner, case .stored(let fileID, _, _, _) = asset else { return nil }
        return CDN.widgetAsset(owner: owner, fileID: fileID, animated: true)
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: min(side / 4, 20)))
            .foregroundStyle(InkColor.secondary)
    }
}

extension EnvironmentValues {
    /// Whose board is being drawn — what a personal widget's pictures are
    /// addressed by.
    @Entry var widgetOwner: UserID? = nil
}
