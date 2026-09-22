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
        // **A label where there is nothing to open, not a dimmed button.** §5.5
        // says a control that cannot work must not look like one that can — and
        // the honest form of that here is *not* `.disabled`, which greys the
        // channel's own name and reads as the app having lost the channel. A
        // server page and a channel whose owner wrote no topic get the title
        // they always had, with no press affordance at all.
        if canOpenTopic {
            Button(action: action) { label }
                .animation(motion.glassMorph, value: name)
                .help("\(name) — what this channel is for")
                .accessibilityLabel(Text(name))
                .accessibilityHint(Text("Shows what this channel is for"))
                // **The scoped exception, exactly as the pins popover is.** §2
                // forbids a presentation modifier on a list ROW because it is
                // evaluated by every row on every pass; this is one toolbar
                // item, evaluated once, and it is the only way to point a
                // surface at the control that opened it.
                .popover(isPresented: topicBinding, arrowEdge: .bottom) {
                    topicContent()
                }
        } else {
            label
                .animation(motion.glassMorph, value: name)
                .help(name)
                .accessibilityLabel(Text(name))
        }
    }

    /// The pill's contents.
    ///
    /// **The horizontal inset is the app's, because the toolbar supplies none.**
    /// A `ToolbarItem` sizes its glass to the label's own bounds, and a label
    /// that is a bare `HStack` has no bounds beyond its ink — so the item gave
    /// this one the vertical padding that comes with its minimum height and
    /// nothing at all sideways. Measured on the running window: 1.5 points from
    /// the capsule's leading edge to the sigil and 1 point from the name to its
    /// trailing edge, against 9 points above and below. That is what reads as
    /// the glyph being crushed against the end of the pill.
    ///
    /// `Spacing.snug` at the ends and `Spacing.tight` between the sigil and the
    /// name, deliberately in that order: the sigil belongs to the name, so the
    /// pair has to read as one object inside the pill rather than as two things
    /// spaced like the pill's own edges.
    private var label: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: symbolName)
                .foregroundStyle(Ink.tertiary)
            Text(name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, Spacing.snug)
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
