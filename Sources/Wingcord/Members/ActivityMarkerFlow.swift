import SwiftUI
import WingcordCore

/// The popout's markers, wrapping — Discord's `badgesContainerPopout`
/// (`flex-wrap`, 8 across, 4 down): a glyph and its words, green where
/// Discord greens them, the clock running.
struct ActivityMarkerFlow: View {
    var markers: [ActivityMarker]
    var liveSince: Date?
    var occurredAt: Date?
    var now: Date

    var body: some View {
        MarkerFlowLayout(spacing: 8, rowSpacing: 4) {
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                let words = text(marker)
                HStack(spacing: 4) {
                    Image(systemName: marker.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(marker.tintsSymbol ? Palette.presenceOnline : Color.white.opacity(0.75))
                    Text(words)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(marker.tintsText ? Palette.presenceOnline : Color.white.opacity(0.75))
                        .lineLimit(1)
                }
                .help(marker.tooltip ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(marker.accessibilityText ?? words))
            }
        }
    }

    private func text(_ marker: ActivityMarker) -> String {
        switch marker.text {
        case .words(let words): return words
        case .clock:
            if let liveSince { return ActivityCardRules.elapsed(since: liveSince, now: now) }
            return occurredAt.map { ActivityCardRules.timeAgo(since: $0, now: now) } ?? ""
        }
    }
}

/// Lays its children out in rows, wrapping at the proposed width.
struct MarkerFlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
