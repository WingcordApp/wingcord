import SwiftUI

/// Over a widget a server hasn't unlocked: what it costs. Editors only — the
/// hub hides a locked widget from everyone else, as Discord's does.
struct ServerHubLockedPlate: View {
    var name: String
    var boostPrice: Int?

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text("Unlock \(name)")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
            if let boostPrice, boostPrice > 0 {
                Label(GuildSpaceFormatting.count(boostPrice, "Boost", "Boosts"), systemImage: "diamond.fill")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF73FA))
            }
            Text("Unlock it by boosting the server.")
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }
}
