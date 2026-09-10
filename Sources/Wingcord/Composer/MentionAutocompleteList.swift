import SwiftUI
import WingcordCore

/// The `@` and `#` list, floating over the transcript above the composer.
///
/// **The same object as `EmojiAutocompleteList`, and deliberately so.** Same
/// material, same row height, same travelling selection pill in a shared
/// namespace, same keyboard contract. Three completion surfaces that looked
/// like three different lists would make the composer feel like three
/// different fields — and only one of them is ever on screen, because the
/// composer's stack picks one.
///
/// **Glass, not a slab.** §4 rule 3: an opaque fill behind a floating surface
/// over a scrolling transcript is the composition that stops it reading as
/// glass at all. It sits directly on the composer and takes the same material,
/// so the two read as one object growing upward.
struct MentionAutocompleteList: View {
    var kind: MentionAutocomplete.Kind
    var query: String
    var items: [MentionCandidate]
    var selection: Int
    var onPick: (MentionCandidate) -> Void
    var onHover: (Int) -> Void

    @Environment(\.motion) private var motion
    @Namespace private var selectionNamespace

    private static let artSide: CGFloat = 20
    private static let rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // No `GlassEffectContainer` around these rows: it PROMOTES its
            // glass elements above ordinary siblings and renders them itself
            // — §4 rule 4 — so a pill in a row's background would be lifted
            // above the face and the name it sits behind. There is no glass
            // in here to contain anyway; the pill is a tinted region.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, isSelected: index == selection)
                        .onHover { if $0 { onHover(index) } }
                        .onTapGesture { onPick(item) }
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.bottom, Spacing.base)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .animation(motion.glassMorph, value: selection)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// What the list is answering, in Discord's own words for the two lists.
    private var header: some View {
        Text(title)
            .font(Typeface.sectionHeader)
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.snug)
            .padding(.bottom, Spacing.base)
            .accessibilityHidden(true)
    }

    private var title: String {
        let subject = kind == .member ? "MEMBERS" : "TEXT CHANNELS"
        // The token is repeated back because the list is derived from it, and
        // a reader who typed `#gen` after a URL needs to see which token was
        // taken.
        return query.isEmpty ? subject : "\(subject)  \(kind.sigil)\(query)"
    }

    private var accessibilityLabel: String {
        kind == .member
            ? "Members matching \(query)"
            : "Channels matching \(query)"
    }

    private func row(_ item: MentionCandidate, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.base) {
            art(item.art)
                .frame(width: Self.artSide, height: Self.artSide)
            Text(item.title)
                .font(.system(.subheadline))
                .foregroundStyle(nameStyle(item, isSelected: isSelected))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.snug)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.quaternary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Self.rowHeight)
        .background {
            if isSelected {
                // **A tinted region inside the panel's material, never a
                // second glass body on it** — §4 rule 2. Matched across the
                // rows so moving down the list is one mark sliding rather
                // than ten fading in and out.
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.selectionFill)
                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
            }
        }
        .contentShape(.rect)
    }

    private func nameStyle(_ item: MentionCandidate, isSelected: Bool) -> AnyShapeStyle {
        if let value = item.nameColor { return AnyShapeStyle(Color(hex: value)) }
        return AnyShapeStyle(isSelected ? Ink.primary : Ink.secondary)
    }

    @ViewBuilder
    private func art(_ art: MentionCandidate.Art) -> some View {
        switch art {
        case .avatar(let url, let monogram):
            AvatarView(url: url, monogram: monogram, side: Self.artSide)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: Self.artSide, height: Self.artSide)
        }
    }
}
