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
    /// Resolved by the chrome, because the pill names channels and server
    /// pages alike and only one of those has a `ChannelKind`.
    var symbolName: String
    /// Whether pressing it does anything. **False where there is no topic** —
    /// a pill that opens onto an empty box is the inert control §5.5 forbids,
    /// and a server page has no topic at all.
    var canOpenTopic: Bool
    var isTopicShown: Bool
    var action: () -> Void
    /// The flyout's contents. A closure rather than the pane, so the toolbar
    /// never builds it for a channel nobody has opened it in — the same reason
    /// the pins and threads panes are closures.
    var topicContent: () -> AnyView

    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: symbolName)
                    .foregroundStyle(Ink.tertiary)
                Text(name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
        }
        .disabled(!canOpenTopic)
        .animation(motion.glassMorph, value: name)
        .help(canOpenTopic ? "\(name) — what this channel is for" : name)
        .accessibilityLabel(Text(name))
        // **The scoped exception, exactly as the pins popover is.** §2 forbids a
        // presentation modifier on a list ROW because it is evaluated by every
        // row on every pass; this is one toolbar item, evaluated once, and it is
        // the only way to point a surface at the control that opened it.
        .popover(isPresented: topicBinding, arrowEdge: .bottom) {
            topicContent()
        }
    }

    /// **The setter may only clear when the store is still showing this one.**
    /// Clearing unconditionally lets a dismissal that arrives while a second
    /// channel's flyout is opening take the new one down with it.
    private var topicBinding: Binding<Bool> {
        Binding(
            get: { isTopicShown },
            set: { if !$0, isTopicShown { action() } }
        )
    }
}
