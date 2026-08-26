import SwiftUI
import WingcordCore

/// The channel name, as a glass capsule in the toolbar.
///
/// **The capsule's width is the label's width.** `#general` and
/// `#really-long-channel-name` are visibly different objects rather than the
/// same slab with different contents — `.fixedSize()` before the glass is what
/// does that, and any `.frame(maxWidth:)` above it defeats it.
///
/// Switching channels **reflows** the capsule rather than swapping it. Two
/// things make that read as one control being re-labelled instead of as two
/// controls cutting:
///
///   - `.animation(motion.glassMorph, value: name)` drives the width change, so
///     the material morphs along with the geometry.
///   - `.contentTransition(.interpolate)` on the label crosses the old text into
///     the new one inside a capsule that is already moving, rather than popping
///     it at the end of the reflow.
///
/// It is a real `ToolbarItem`, which is not a detail. A glass control drawn in a
/// hand-made band samples **the content behind it** — a scrolling transcript —
/// and resolves against whatever happens to be passing, so it looks wrong beside
/// the split view's own sidebar toggle two inches away. The same API inside a
/// real toolbar samples the toolbar's material and looks correct. Same window,
/// same modifier; the difference is being a toolbar item.
struct ChannelPill: View {
    var name: String
    var kind: ChannelKind
    var action: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: kind.symbolName)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                Text(name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .interactiveChrome()
        .animation(motion.glassMorph, value: name)
        .accessibilityLabel(Text(name))
    }
}
