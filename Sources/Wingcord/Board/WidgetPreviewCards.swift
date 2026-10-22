import SwiftUI
import WingcordCore

/// The popout's widgets, stacked (module `657538`, in `80330`'s stack): the
/// first card whole, the edge of the next beneath it, and every card — and the
/// edge — opening the board, where the rest are.
struct ProfileWidgetStack: View {
    var previews: [WidgetPreview]
    var ground: ProfileGround
    /// The card's width, which an application card's split is taken of.
    var width: CGFloat
    /// The column beside a conversation, where Discord sets the strip's label a
    /// size up.
    var isColumn: Bool
    var openBoard: () -> Void

    var body: some View {
        if let first = previews.first {
            ProfileCardStack(hasMore: previews.count > 1, ground: ground, expand: openBoard) {
                switch first {
                case .application(let widget):
                    MiniApplicationWidgetCard(widget: widget, ground: ground, width: width, open: openBoard)
                case .games(let collection):
                    GameCollectionRow(
                        collection: collection,
                        ground: ground,
                        isColumn: isColumn,
                        openBoard: openBoard
                    )
                case .personal(_, let widget):
                    PersonalWidgetPreview(widget: widget, ground: ground, open: openBoard)
                case .clips(_, let clips):
                    ClipsGalleryPreview(clips: clips, ground: ground, open: openBoard)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Widgets"))
        }
    }
}

/// An application widget on the popout: its `mini_profile` surface (module
/// `139730`, laid out by `794248`).
///
/// ```
/// ▣ Gramophone                 ┌──────┐
/// 102.3k Scrobbles ≋           │ art  │   seven parts words,
/// View All Stats               └──────┘   three parts picture
/// ```
///
/// A `…_contained_stat` layout boxes its picture; a `…_hero_stat` layout runs
/// it the card's full height behind the column, fading in from its left.
struct MiniApplicationWidgetCard: View {
    var widget: MiniApplicationWidget
    var ground: ProfileGround
    var width: CGFloat
    var open: () -> Void

    private static let iconSide: CGFloat = 16
    /// One line of the stat tall — Discord's `1lh`.
    private static let statIconSide: CGFloat = 14

    /// Discord's `7fr 3fr` with four points between.
    private var pictureWidth: CGFloat { ((width - Spacing.tight) * 0.3).rounded() }

    var body: some View {
        ProfilePanelButton(ground: ground, action: open) {
            HStack(alignment: .top, spacing: Spacing.tight) {
                words
                    .frame(maxWidth: .infinity, alignment: .leading)
                containedPicture
            }
            .background(alignment: .trailing) { heroPicture }
        }
        .accessibilityLabel(Text(widget.name))
        .accessibilityValue(Text(widget.surface.headline?.value ?? ""))
        .accessibilityHint(Text("Opens their board"))
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                RemoteImage(url: widget.iconURL, side: Self.iconSide) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Palette.groupedFill)
                }
                .frame(width: Self.iconSide, height: Self.iconSide)
                .clipShape(.rect(cornerRadius: 2, style: .continuous))

                Text(widget.name)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 0) {
                if let headline = widget.surface.headline {
                    HStack(spacing: 2) {
                        Text(headline.value)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                        if let icon = headline.iconURL {
                            RemoteImage(url: icon, side: Self.statIconSide) { Color.clear }
                                .aspectRatio(contentMode: .fit)
                                .frame(width: Self.statIconSide, height: Self.statIconSide)
                        }
                    }
                }
                Text("View All Stats")
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
            }
            .padding(.vertical, 2)
        }
        .padding(Spacing.base)
    }

    /// The boxed picture, whole, on a square plate eight points in — or, for a
    /// hero layout, the empty column the picture fills from behind.
    @ViewBuilder
    private var containedPicture: some View {
        if !widget.surface.isHero, let url = widget.surface.containedImageURL {
            let side = pictureWidth - Spacing.base * 2
            let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            RemoteImage(url: url, side: side) { Color.clear }
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .background(Palette.groupedFill, in: shape)
                .clipShape(shape)
                .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
                .padding(Spacing.base)
        } else {
            Color.clear.frame(width: pictureWidth, height: 0)
        }
    }

    /// The hero picture: the column's full width at its natural height, hung
    /// from the card's top, cut at its foot and dissolving in from the left.
    @ViewBuilder
    private var heroPicture: some View {
        if widget.surface.isHero, let url = widget.surface.heroImageURL {
            Color.clear
                .overlay(alignment: .top) {
                    RemoteImage(url: url, side: pictureWidth, bucket: .artwork) { Color.clear }
                        .aspectRatio(contentMode: .fit)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .clipped()
                .fadingInFromLeading()
                .frame(width: pictureWidth)
        }
    }
}

/// A widget the person wrote, on the popout (module `657538`): its heading
/// under Nitro's mark — personal widgets are a Nitro perk — and what its cover
/// says, with the cover's picture at the trailing edge.
///
/// **No fields here.** Discord previews a widget by its first section, and
/// every widget its editor or this one writes leads with the cover.
struct PersonalWidgetPreview: View {
    var widget: PersonalWidget
    var ground: ProfileGround
    var open: () -> Void

    private static let pictureSize = CGSize(width: 100, height: 72)
    private static let untitledPictureHeight: CGFloat = 48
    /// Discord's `--radius-xs`.
    private static let pictureCorner: CGFloat = 4

    private var hasCover: Bool {
        !widget.cover.title.isEmpty || widget.cover.image != nil
    }

    var body: some View {
        ProfilePanelButton(ground: ground, action: open) {
            Group {
                if hasCover { cover } else { plain }
            }
            .padding(Spacing.base)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(Text(widget.header.isEmpty ? "Personal Widget" : widget.header))
        .accessibilityHint(Text("Opens their board"))
    }

    private var heading: some View {
        HStack(spacing: Spacing.tight) {
            BrandGlyph(service: BrandMark.nitro)
                .fill(InkColor.secondary)
                .frame(width: 12, height: 12)
            Text(widget.header)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
    }

    private var cover: some View {
        HStack(alignment: .top, spacing: Spacing.tight) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                heading
                VStack(alignment: .leading, spacing: 3) {
                    if !widget.cover.title.isEmpty {
                        Text(widget.cover.title)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                    }
                    Text("View Widget")
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let image = widget.cover.image {
                PersonalAssetImage(asset: image, side: Self.pictureSize.width)
                    .frame(
                        width: Self.pictureSize.width,
                        height: widget.cover.title.isEmpty
                            ? Self.untitledPictureHeight
                            : Self.pictureSize.height
                    )
                    .clipShape(.rect(cornerRadius: Self.pictureCorner, style: .continuous))
                    // Discord lets the picture into the card's padding, four
                    // points each way.
                    .padding([.vertical, .trailing], -Spacing.tight)
            }
        }
    }

    private var plain: some View {
        HStack(spacing: Spacing.tight) {
            heading
            Spacer(minLength: Spacing.tight)
            Text("View Widget")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(InkColor.secondary)
        }
        .padding(.vertical, Spacing.tight)
    }
}
