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
/// **The stored form has no address this client knows, and it is not invented
/// here.** A saved asset arrives as `{"file_id":"1547200273017192144","width":
/// 256,"height":256,"is_animated":false}` and no capture on disk contains a
/// request that fetches one — every upload in `Custom widget.har` ends at the
/// `PUT` to Google's bucket, and no profile since has been reloaded with a
/// personal widget on it. Guessing a CDN path is how a plausible URL 404s
/// silently on every card, so a stored picture draws its plate until the request
/// is captured. `HANDOFF.md` records this as the one field the feature is
/// missing.
///
/// A picture the reader has *just* chosen is a different case and does draw: it
/// is still bytes in the editor, and the editor's own card renders those rather
/// than asking the network for something that has not been sent yet.
struct PersonalAssetImage: View {
    var asset: PersonalWidget.Asset
    var side: CGFloat

    var body: some View {
        Rectangle()
            .fill(Palette.skeletonPlate)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: min(side / 4, 20)))
                    .foregroundStyle(InkColor.tertiary)
            }
            .accessibilityLabel(Text("Picture"))
    }
}
