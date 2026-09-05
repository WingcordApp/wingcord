import SwiftUI

/// Packs slabs into columns, shortest column first, honouring a span.
///
/// **This is the layout that replaces the two-column profile**, and the reason
/// it is a `Layout` rather than a `LazyVGrid` is that these slabs disagree about
/// height by a factor of five. A grid gives every cell in a row the tallest
/// cell's height, so a Roles chip-flow beside a Games-in-Rotation list becomes a
/// short chip-flow with four hundred points of air under it — which is exactly
/// the dead space that made the old surface feel like a form.
///
/// Shortest-column-first is the standard masonry pack and it is stable: the same
/// input always produces the same arrangement, so nothing shuffles when a game's
/// name arrives and a slab grows.
///
/// A subview declares how many columns it wants with `.masonrySpan(_:)`. A span
/// wider than the grid is clamped, so the same tree lays out at one column in a
/// narrow window without any call site knowing.
nonisolated struct MasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    init(columns: Int, spacing: CGFloat = Spacing.margin) {
        self.columns = max(1, columns)
        self.spacing = spacing
    }

    /// Where every subview ended up, and how tall the whole thing is.
    ///
    /// Cached between `sizeThatFits` and `placeSubviews` so the pack runs once
    /// per pass rather than twice — SwiftUI calls both with the same proposal,
    /// and this arithmetic is over every slab on the surface.
    struct Cache {
        var width: CGFloat = .nan
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Invalidate on any change to the set of subviews: the pack depends on
        // every one of their heights.
        cache.width = .nan
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? 0
        pack(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        pack(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() where index < cache.frames.count {
            let frame = cache.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func pack(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard width > 0 else { return }
        guard cache.width != width else { return }
        cache.width = width

        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        guard columnWidth > 0 else { return }

        /// The bottom of each column so far.
        var bottoms = [CGFloat](repeating: 0, count: columns)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)

        for subview in subviews {
            let span = min(max(subview[MasonrySpan.self], 1), columns)
            let slabWidth = columnWidth * CGFloat(span) + spacing * CGFloat(span - 1)
            let height = subview.sizeThatFits(
                ProposedViewSize(width: slabWidth, height: nil)
            ).height

            // The leftmost start where `span` consecutive columns are lowest.
            // Ties break leftward, which keeps the arrangement reading in the
            // order the slabs were declared.
            var start = 0
            var best = CGFloat.infinity
            for candidate in 0...(columns - span) {
                let top = bottoms[candidate..<(candidate + span)].max() ?? 0
                if top < best - 0.5 {
                    best = top
                    start = candidate
                }
            }
            let top = best.isFinite ? best : 0
            let x = CGFloat(start) * (columnWidth + spacing)
            frames.append(CGRect(x: x, y: top, width: slabWidth, height: height))
            for column in start..<(start + span) {
                bottoms[column] = top + height + spacing
            }
        }

        cache.frames = frames
        // The tallest column, less the trailing gap it added.
        cache.height = max((bottoms.max() ?? 0) - spacing, 0)
    }
}

/// How many columns a slab wants.
///
/// `nonisolated` so the layout — which is itself nonisolated, because SwiftUI
/// runs it off the main actor — can read it. Without it the conformance is
/// main-actor-isolated and the pack cannot see the key at all.
private nonisolated struct MasonrySpan: LayoutValueKey {
    static let defaultValue: Int = 1
}

extension View {
    /// Asks for `columns` columns in a `MasonryLayout`. Clamped to the grid, so
    /// a slab that wants three still lays out in a one-column window.
    func masonrySpan(_ columns: Int) -> some View {
        layoutValue(key: MasonrySpan.self, value: columns)
    }
}
