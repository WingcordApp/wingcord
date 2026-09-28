import SwiftUI

/// A label that appears beside whatever the pointer is resting on.
///
/// **`.help()` is not this, and the difference is the whole reason it exists.**
/// A system tooltip waits out a delay measured in most of a second, appears in
/// the system's own yellow-grey box, and is drawn in a style nothing else in
/// this app shares. A rail of ninety-seven wordless 44-point tiles is the one
/// surface where "what is that?" is the *only* question every element raises, so
/// the answer has to arrive while the reader is still asking it.
///
/// A popover rather than an overlay: the rail is a clipping `ScrollView`, and an
/// overlay drawn inside it is cut off at the column's edge — which is exactly
/// where a flyout needs to go. It is the same control `BadgeRow` opens on hover
/// for the same reason.
///
/// **The dwell is a cancelled `Task`, not a timer.** Sweeping the pointer down a
/// rail crosses a dozen tiles in half a second, and a flyout per crossing is a
/// dozen popovers materialising and dying. One task per hover, cancelled the
/// moment the pointer leaves, costs nothing when nobody is hovering.
/// How long the pointer has to rest before a hover flyout appears.
///
/// Short enough to read as instant on a tile you meant to point at, long enough
/// that crossing one on the way somewhere else shows nothing. At file scope
/// because a generic type cannot hold a stored static.
private let hoverFlyoutDwell = Duration.milliseconds(180)

struct HoverFlyout<Flyout: View>: ViewModifier {
    var edge: Edge = .trailing
    /// What opens. A label for most controls — `FlyoutLabel` — and a small card
    /// for the few Discord explains at more length, such as a server's mark.
    @ViewBuilder var flyout: () -> Flyout


    @State private var isShown = false
    @State private var dwellTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                dwellTask?.cancel()
                guard hovering else {
                    dwellTask = nil
                    // A `@State` write of an equal value still invalidates.
                    if isShown { isShown = false }
                    return
                }
                dwellTask = Task {
                    try? await Task.sleep(for: hoverFlyoutDwell)
                    guard !Task.isCancelled else { return }
                    isShown = true
                }
            }
            .popover(
                isPresented: Binding(
                    get: { isShown },
                    // Dismissal is owned by the pointer leaving, not by the
                    // popover: clearing here as well would fight `onHover` and
                    // flicker.
                    set: { if !$0 { isShown = false } }
                ),
                arrowEdge: edge
            ) {
                flyout()
                    // The label carries the material; the popover must carry
                    // none, or two are stacked and the result reads as frost.
                    .presentationBackground(.clear)
            }
    }
}

/// The label inside a hover flyout.
///
/// One line, whole. It sizes to its text rather than wrapping — there is nothing
/// to wrap against in a window of its own, and a truncated server name is the
/// one thing this control must never produce.
struct FlyoutLabel: View {
    var text: String
    var wrapsAt: CGFloat?

    var body: some View {
        Text(text)
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(InkColor.primary)
            .lineLimit(wrapsAt == nil ? 1 : nil)
            .fixedSize(horizontal: wrapsAt == nil, vertical: wrapsAt != nil)
            .frame(maxWidth: wrapsAt, alignment: .leading)
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            // No material of its own: the popover's glass is the body — §4.9.
            // It is an answer about the thing under the pointer, so it must
            // never become the thing under the pointer.
            .allowsHitTesting(false)
            // The control it hangs off already carries the label for VoiceOver;
            // a second copy would be read twice.
            .accessibilityHidden(true)
    }
}

extension View {
    /// Names this control beside itself while the pointer rests on it.
    ///
    /// - Parameter wrapsAt: the width the label wraps at, or nil for one line
    ///   that sizes to its text. A server name is a few words and belongs on one
    ///   line; a custom status is a sentence somebody wrote, and one line of it
    ///   would be a popover wider than the window.
    func hoverFlyout(
        _ label: String,
        edge: Edge = .trailing,
        wrapsAt: CGFloat? = nil
    ) -> some View {
        modifier(HoverFlyout(edge: edge) { FlyoutLabel(text: label, wrapsAt: wrapsAt) })
    }

    /// Opens `flyout` beside this control while the pointer rests on it.
    func hoverFlyout<Flyout: View>(
        edge: Edge = .trailing,
        @ViewBuilder _ flyout: @escaping () -> Flyout
    ) -> some View {
        modifier(HoverFlyout(edge: edge, flyout: flyout))
    }
}
