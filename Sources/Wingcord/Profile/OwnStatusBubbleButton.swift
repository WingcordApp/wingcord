import SwiftUI

/// The reader's own status bubble as the button that edits it.
///
/// **The button is moved, not the bubble inside it.** The bubble rests below
/// the artwork's edge by an offset; applied inside a button's label, the
/// press was taken where the label was laid out — above the bubble — so only
/// its top few points opened the editor (Alex, 2026-11-17: "I have to press
/// on a specific location"; `StatusBubblePressTests`). Offsetting the button
/// itself moves its press area with what is drawn.
struct OwnStatusBubbleButton: View {
    var bubble: CustomStatusBubble
    var action: () -> Void

    var body: some View {
        Button(action: action) { unshifted }
            .buttonStyle(.plain)
            .offset(y: bubble.restingOffset)
    }

    private var unshifted: CustomStatusBubble {
        var copy = bubble
        copy.appliesRestingOffset = false
        return copy
    }
}
