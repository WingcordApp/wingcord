import SwiftUI

/// The pill beside a card's title: "3d left" in the accent while a competition
/// runs, "Ended" in grey once it's over (Discord's own two colours).
struct ServerHubBadge: View {
    var text: String
    var help: String
    var isMuted: Bool

    var body: some View {
        Text(text)
            .font(.system(.caption, weight: .bold))
            .foregroundStyle(isMuted ? Ink.secondary : Palette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isMuted ? Ink.quaternary : Palette.accent.opacity(0.16), in: .capsule)
            .help(help)
    }
}
