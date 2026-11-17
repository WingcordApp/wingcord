import SwiftUI

/// "LIVE": somebody is sharing their screen — Discord's red badge, as glass
/// tinted red rather than a painted pill.
///
/// **A word as well as a colour** (HIG, Accessibility: don't convey state by
/// colour alone).
struct CallLiveBadge: View {
    var isCompact = false

    var body: some View {
        Text("LIVE")
            .font(.system(size: isCompact ? 9 : 11, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(TileGlass.ink)
            .padding(.horizontal, isCompact ? 5 : 7)
            .padding(.vertical, isCompact ? 2 : 3)
            .tileGlass(tint: Palette.destructive.opacity(0.85))
            .accessibilityLabel(Text("Sharing their screen"))
    }
}
