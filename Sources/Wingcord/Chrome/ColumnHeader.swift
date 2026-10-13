import SwiftUI

// MARK: - The right-hand column's header
//
// Every transcript in the column — a thread, a post, a previewed channel, a
// message request, a voice channel's chat — floats the same header over it: one
// glass capsule naming what is open, and one glass circle per thing it can do,
// merged in a `GlassEffectContainer` so they read as a cluster rather than as
// unrelated pills. `.clear` rather than `.regular` for the reason §4 gives: what
// passes underneath is a transcript, and `.regular` frosts it into a grey slab.

/// What the column is showing: its glyph and its name, in a glass capsule.
struct ColumnHeaderIdentity<Glyph: View, Accessory: View>: View {
    var name: String
    /// The hover text — a topic or a subtitle where there is one.
    var help: String
    @ViewBuilder var glyph: Glyph
    /// Facts about what is open that are not controls, such as a muted bell.
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Spacing.tight) {
            glyph
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)

            Text(name)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            accessory
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: ColumnHeaderControl.side)
        // Navigation chrome over the column: `.regular`, the HIG's default.
        .glassEffect(.regular, in: .capsule)
        .help(help)
    }
}

extension ColumnHeaderIdentity where Accessory == EmptyView {
    init(name: String, help: String, @ViewBuilder glyph: () -> Glyph) {
        self.init(name: name, help: help, glyph: glyph, accessory: { EmptyView() })
    }
}

/// One circular control in the header's cluster.
struct ColumnHeaderControl: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    /// The capsule's height and each circle's diameter, so the two line up.
    static let side = Metrics.control + Spacing.base

    var body: some View {
        Button(action: action) {
            Self.glyph(systemImage)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    /// The circle's glyph, for a control in the cluster that is more than a
    /// button — a thread's ⋯, which raises its menu.
    static func glyph(_ systemImage: String) -> some View {
        Image(symbol: systemImage)
            .font(Typeface.controlGlyph)
            .foregroundStyle(Ink.secondary)
            .frame(width: side, height: side)
            .contentShape(.circle)
    }
}
