import SwiftUI

/// The band's Fill: the call grows down the whole conversation, and comes
/// back. Vertical arrows, because the band grows down the conversation; the
/// diagonal ones are Full Screen's, as they are across macOS.
struct CallExpandControl: View {
    @Binding var isExpanded: Bool

    var body: some View {
        CallCapsuleAccessory(
            title: isExpanded ? "Shrink the Call" : "Fill the Conversation",
            systemImage: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
            action: toggle
        )
    }

    private func toggle() {
        isExpanded.toggle()
    }
}
