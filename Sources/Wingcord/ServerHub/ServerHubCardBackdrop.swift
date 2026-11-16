import SwiftUI

/// A card's own picture, heavily blurred and dimmed, under its material.
struct ServerHubCardBackdrop: View {
    var url: URL?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let url, !reduceTransparency {
            RemoteImage(url: url, side: 160) {
                Color.clear
            }
            .scaledToFill()
            .blur(radius: 48, opaque: true)
            .saturation(1.3)
            .opacity(0.45)
            .accessibilityHidden(true)
        }
    }
}
