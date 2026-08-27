import SwiftUI
import WingcordCore

/// The channel name, in the toolbar.
///
/// **It draws no glass of its own, and that is the fix rather than an
/// omission.** A `ToolbarItem` on macOS 27 is already given the system's glass
/// backing at the system's size. Adding `.glassEffect` inside one puts a second
/// material inside the first — the capsule-inside-a-rounded-rect that made this
/// read as a pill sitting on another pill — and it is the exact case
/// `INVARIANTS.md` §4 rule 2 forbids: never stack glass on glass.
///
/// The corollary from §1 is the other half: *toolbar controls take the system's
/// size and glass; do not hand-size them.* So there is no `.frame(height:)` and
/// no `.fixedSize()` here either. Both were compensating for a material this
/// view should never have been applying, and a hand-set height inside a toolbar
/// item is what makes a control disagree with the split view's own sidebar
/// toggle two inches away.
///
/// What is left is the part only this view can know: switching channels
/// **reflows** the label rather than cutting between two of them.
/// `.contentTransition(.interpolate)` crosses the old text into the new one, and
/// `.animation(motion.glassMorph, value: name)` drives the width change so the
/// system's material morphs along with the geometry.
struct ChannelPill: View {
    var name: String
    var kind: ChannelKind
    var action: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(Ink.tertiary)
                Text(name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
        }
        .animation(motion.glassMorph, value: name)
        .help(name)
        .accessibilityLabel(Text(name))
    }
}
