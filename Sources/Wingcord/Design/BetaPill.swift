import SwiftUI

/// Discord's "BETA" badge (`TextBadge type: "beta"`, primary): small
/// uppercase words on a Blurple capsule, beside a feature's title.
struct BetaPill: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: 0x5865F2), in: .capsule)
            .accessibilityLabel(Text("Beta"))
    }
}
