import CoreGraphics
import SwiftUI

/// Discord's Super Reaction mark: a face, with a sparkle at two corners.
///
/// **Converted from Discord's own SVG, not traced** — module `343032`, the
/// icon on the reaction picker's toggle. Its paths are relative commands and
/// elliptic arcs; `VectorPath` takes absolute `M`/`L`/`C`/`Z` only, so every
/// arc was resolved to cubics and the result rasterised against the original:
/// 43 pixels of 230,400 differ, every one on an antialiased edge, at twenty
/// times the size this is drawn.
///
/// **Two shapes, because Discord's SVG is two paths with two fill rules.** The
/// face is even-odd, which is what cuts its eyes and mouth out; the sparkles
/// are non-zero, and filled even-odd their own overlapping curves punch
/// slivers out of them.
struct SuperReactionGlyph: View {
    var body: some View {
        ZStack {
            Outline(key: "superReaction.face", outline: Self.face)
                .fill(style: FillStyle(eoFill: true))
            Outline(key: "superReaction.sparkles", outline: Self.sparkles)
                .fill()
        }
        .accessibilityHidden(true)
    }

    nonisolated static let face =
        """
        M 14.61 2.26 C 14.86 1.92 14.77 1.34 14.36 1.26 C 10.584 0.427 6.648 1.637 \
        3.993 4.448 C 1.337 7.259 0.353 11.258 1.4 14.98 C 1.5 15.31 1.92 15.43 2.23 \
        15.28 C 3.63 14.6 5.53 15.13 6.16 16.85 L 6.3 17.23 C 6.38 17.43 6.54 17.6 \
        6.75 17.68 L 7.13 17.82 C 7.888 18.098 8.494 18.684 8.795 19.433 C 9.096 \
        20.183 9.065 21.025 8.71 21.75 C 8.55 22.06 8.66 22.48 9.01 22.58 C 12.729 \
        23.622 16.722 22.64 19.533 19.991 C 22.343 17.342 23.56 13.414 22.74 9.64 C \
        22.64 9.23 22.07 9.14 21.74 9.39 C 20.998 9.937 20.041 10.103 19.157 9.838 C \
        18.274 9.572 17.567 8.906 17.25 8.04 L 17 7.43 C 16.917 7.214 16.746 7.043 \
        16.53 6.96 L 15.95 6.74 C 15.087 6.422 14.424 5.717 14.159 4.836 C 13.893 \
        3.956 14.057 3.002 14.6 2.26 Z M 6.5 11 C 7.328 11 8 10.328 8 9.5 C 8 8.672 \
        7.328 8 6.5 8 C 5.672 8 5 8.672 5 9.5 C 5 10.328 5.672 11 6.5 11 Z M 15.5 14 C \
        16.328 14 17 13.328 17 12.5 C 17 11.672 16.328 11 15.5 11 C 14.672 11 14 \
        11.672 14 12.5 C 14 13.328 14.672 14 15.5 14 Z M 12.71 14.54 C 12.98 14.11 \
        12.73 13.59 12.28 13.45 L 8.22 12.22 C 7.77 12.08 7.28 12.37 7.26 12.88 C 7.17 \
        14.247 8.012 15.503 9.31 15.94 C 10.6 16.34 11.97 15.73 12.71 14.54 Z
        """
    nonisolated static let sparkles =
        """
        M 19.09 0.63 C 19.231 0.249 19.594 -0.004 20 -0.004 C 20.406 -0.004 20.769 \
        0.249 20.91 0.63 L 21.25 1.56 C 21.452 2.112 21.888 2.548 22.44 2.75 L 23.37 \
        3.09 C 23.751 3.231 24.004 3.594 24.004 4 C 24.004 4.406 23.751 4.769 23.37 \
        4.91 L 22.44 5.25 C 21.888 5.452 21.452 5.888 21.25 6.44 L 20.91 7.37 C 20.769 \
        7.751 20.406 8.004 20 8.004 C 19.594 8.004 19.231 7.751 19.09 7.37 L 18.75 \
        6.44 C 18.548 5.888 18.112 5.452 17.56 5.25 L 16.63 4.91 C 16.249 4.769 15.996 \
        4.406 15.996 4 C 15.996 3.594 16.249 3.231 16.63 3.09 L 17.56 2.75 C 18.112 \
        2.548 18.548 2.112 18.75 1.56 L 19.09 0.63 Z M 2.7 17.55 C 2.821 17.212 3.141 \
        16.987 3.5 16.987 C 3.859 16.987 4.179 17.212 4.3 17.55 L 4.56 18.26 C 4.763 \
        18.806 5.194 19.237 5.74 19.44 L 6.44 19.7 C 6.778 19.821 7.003 20.141 7.003 \
        20.5 C 7.003 20.859 6.778 21.179 6.44 21.3 L 5.74 21.56 C 5.194 21.763 4.763 \
        22.194 4.56 22.74 L 4.3 23.44 C 4.179 23.778 3.859 24.003 3.5 24.003 C 3.141 \
        24.003 2.821 23.778 2.7 23.44 L 2.44 22.74 C 2.237 22.194 1.806 21.763 1.26 \
        21.56 L 0.56 21.3 C 0.222 21.179 -0.003 20.859 -0.003 20.5 C -0.003 20.141 \
        0.222 19.821 0.56 19.7 L 1.26 19.44 C 1.806 19.237 2.237 18.806 2.44 18.26 L \
        2.7 17.56 Z
        """

    /// One outline on its 24-unit grid, scaled into whatever box it is given.
    ///
    /// `nonisolated`: a `Shape` is asked for its path off the main actor, and
    /// this module's default would otherwise put it on it — `INVARIANTS.md`
    /// §4.87. It carries its outline's text and parses through `MarkCache`,
    /// the lock `BrandGlyph` already uses, so each outline is parsed once for
    /// the process rather than once per size.
    private nonisolated struct Outline: Shape {
        var key: String
        var outline: String

        func path(in rect: CGRect) -> Path {
            guard let path = MarkCache.shared.path(for: key, outline: outline) else { return Path() }
            let scale = min(rect.width, rect.height) / 24
            var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: scale, y: scale)
            return Path(path.copy(using: &transform) ?? path)
        }
    }
}
