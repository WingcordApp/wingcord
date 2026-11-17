import SwiftUI

/// "Join Wordle": a second way in, beside the call's — it joins the call
/// first, then the game (decision 2's order).
///
/// **The same size as Join, told apart by style** (HIG, Buttons: "Distinguish
/// the preferred choice by style, not size"): regular glass with the game's
/// icon, while the call's own Join is the prominent one.
struct CallLobbyActivityButton: View {
    var activity: CallActivityPresentation
    var join: () -> Void

    var body: some View {
        Button(action: join) {
            HStack(spacing: Spacing.base) {
                RemoteImage(url: activity.iconURL, side: 18) { Color.clear }
                    .frame(width: 18, height: 18)
                    .clipShape(.rect(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
                Text(activity.isStarting ? "Joining\u{2026}" : "Join \(activity.name)")
                    .lineLimit(1)
            }
            .font(.system(.body, weight: .semibold))
            .padding(.horizontal, Spacing.tight)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .fixedSize()
        .disabled(activity.isStarting)
        .help(activity.hostName.map { "\($0) is playing \(activity.name)" } ?? activity.name)
    }
}
