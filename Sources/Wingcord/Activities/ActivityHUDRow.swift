import SwiftUI

/// What the sidebar's activity row shows, read once by its container.
struct ActivityHUDPresentation: Equatable {
    var name: String
    var iconURL: URL?
    /// Where it runs: the person for a DM, the channel otherwise.
    var place: String?
}

/// The activity the reader is in, at the sidebar's foot — Discord's panel
/// over Voice Connected (Alex, 2026-11-18, his Image 155: "add the activity
/// HUD too, like the voice HUD"): its icon, its name, where it runs, and a
/// way out.
///
/// **The row goes back to the game; the door leaves it.** In a call it heads
/// the call's card with a hairline under it; with no call it is a card of its
/// own (`ActivityHUDCard`).
struct ActivityHUDRow: View {
    var activity: ActivityHUDPresentation
    var open: () -> Void
    var leave: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button(action: open) {
                HStack(spacing: Spacing.base) {
                    RemoteImage(url: activity.iconURL, side: 32) { Color.clear }
                        .frame(width: 32, height: 32)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                        if let place = activity.place {
                            Text(place)
                                .font(.caption)
                                .foregroundStyle(InkColor.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Return to Activity")
            .accessibilityLabel(Text(activity.place.map { "\(activity.name), in \($0)" } ?? activity.name))
            .accessibilityHint(Text("Returns to the activity"))

            Button("Leave Activity", systemImage: "rectangle.portrait.and.arrow.right", action: leave)
                .labelStyle(.glassCircleIcon)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Leave Activity")
        }
    }
}

/// The activity row on a card of its own, for an activity with no call
/// around it — the voice HUD's card, so the two read as one family.
struct ActivityHUDCard: View {
    var activity: ActivityHUDPresentation
    var open: () -> Void
    var leave: () -> Void

    var body: some View {
        ActivityHUDRow(activity: activity, open: open, leave: leave)
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
            .padding(.horizontal, Spacing.base)
    }
}
