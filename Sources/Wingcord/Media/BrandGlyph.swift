import SwiftUI

/// One brand mark, as a shape.
///
/// A `Shape` rather than an `Image`: it takes whatever foreground style it is
/// drawn in, scales to any box without a second asset, and carries no bitmap to
/// decode — so the first frame a profile card draws already has it.
nonisolated struct BrandGlyph: Shape {
    var service: String

    func path(in rect: CGRect) -> Path {
        guard let mark = BrandMark.path(for: service) else { return Path() }
        // Uniform, so a mark authored square stays square in a rect that is not.
        let scale = min(rect.width, rect.height) / BrandMark.side
        var transform = CGAffineTransform(
            translationX: rect.midX - BrandMark.side * scale / 2,
            y: rect.midY - BrandMark.side * scale / 2
        )
        .scaledBy(x: scale, y: scale)
        guard let scaled = mark.copy(using: &transform) else { return Path() }
        return Path(scaled)
    }
}

/// The mark for one connected account: the brand's own glyph on the brand's own
/// colour.
///
/// **The colour is the ground, not the glyph**, which is the only arrangement
/// that works for all of them: four of these brands are black, and a black glyph
/// on this app's near-black card is an empty square. On a plate, black is a
/// plate that recedes into the card with a white mark floating on it — which is
/// exactly how Discord draws Steam, and how the marks were designed to be seen.
///
/// Whether that mark is white or black is decided by the plate's luminance
/// rather than by a per-brand exception, so a brand added later cannot be the
/// one that comes out illegible.
///
/// A service with no mark — `domain`, or anything Discord adds after this was
/// written — gets a neutral plate and a symbol. It stays legible and stays
/// obviously *not* a brand, which is the honest answer for an unknown one.
struct ConnectionMark: View {
    var service: String
    var side: CGFloat

    private var corner: CGFloat { side * 0.28 }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(ground)
            .overlay {
                if BrandMark.mark(for: service) != nil {
                    BrandGlyph(service: service)
                        .fill(foreground)
                        .padding(side * 0.21)
                } else {
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: side * 0.52, weight: .semibold))
                        .foregroundStyle(foreground)
                }
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }

    private var ground: Color {
        guard let mark = BrandMark.mark(for: service) else { return Palette.surfaceRaised }
        return Color(hex: mark.tint)
    }

    private var foreground: Color {
        guard let mark = BrandMark.mark(for: service) else { return InkColor.secondary }
        return BrandMark.prefersLightGlyph(on: mark.tint) ? .white : .black
    }

    /// `domain` is a website rather than a brand, so it takes the symbol for
    /// one. Everything else unknown is a link.
    private var fallbackSymbol: String {
        service == "domain" ? "globe" : "link"
    }
}
