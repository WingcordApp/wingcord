import SwiftUI
import WingcordCore

// MARK: - Activities in a call
//
// Discord's two ways into an activity from inside a call, both reading the
// shelf's own ranking (`AppModel.suggestedActivities`):
//
// - **the call's Activities control**, which opens the launcher itself, as a
//   large card over the call (`ActivityLauncher`, context `.call`; decision 5:
//   one launcher, where Discord has a mini shelf and a See All);
// - **the suggestion under a server's call** — its
//   `VC_TILE_ACTIVITIES_ENTRY_POINT`: "Looking for something to do? Start a
//   game or video playlist instantly.", the top three at 16:9, and "Don't show
//   again".
//
// A tile launches into the call through the launcher's own path.

/// The suggestion under a server's call — Discord's activity entry point.
///
/// Gone for good after "Don't show again", and for this call after ×.
struct ActivitySuggestionCard: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @State private var isClosed = false

    private static let tile = CGSize(width: 192, height: 108)

    var body: some View {
        let suggestions = model.suggestedActivities(3)
        if !isClosed, !AppSettings.shared.hidesActivitySuggestions, !suggestions.isEmpty {
            VStack(spacing: Spacing.snug) {
                Text("Looking for something to do?\nStart a game or video playlist instantly.")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center)
                HStack(spacing: Spacing.snug) {
                    ForEach(suggestions) { row in
                        ActivityArtTile(row: row, size: Self.tile) { launch(row.id) }
                    }
                }
                Button("Don't show again") { AppSettings.shared.hidesActivitySuggestions = true }
                    .buttonStyle(.plain)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(Ink.secondary)
            }
            .padding(Spacing.margin)
            .frame(maxWidth: .infinity)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.glass, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button { isClosed = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel(Text("Close"))
                .padding(Spacing.base)
            }
            .task { await model.sessionController.loadActivityDirectory() }
        }
    }

    private func launch(_ id: ApplicationID) {
        guard let app = model.activityApp(id) else { return }
        Task { await model.sessionController.startActivity(app, in: channelID, section: nil) }
    }
}

/// An activity's cover art as a tile, its name for VoiceOver and the pointer.
/// The call's Activities control's first answer — Discord's Activities Mini
/// Shelf: "Suggested Activities", "See All ›", and the shelf's top five, in
/// its own ranking (`AppModel.suggestedActivities`). The rebuild had sent the
/// control straight to the full launcher (Alex, 2026-11-18: "add back the
/// suggested activities flyout"); See All is the way there now.
struct SuggestedActivitiesFlyout: View {
    var channelID: ChannelID
    var seeAll: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    /// Three cards across — the launcher's own (`ActivityGridCard`), so the
    /// flyout and the launcher See All opens read as one design (Alex,
    /// 2026-11-18: "smooth, cool, beautiful").
    private static let cardWidth: CGFloat = 196

    var body: some View {
        let suggestions = model.suggestedActivities(3)
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                Text("Suggested Activities")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Spacing.margin)
                Button(action: seeAll) {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right")
                            .font(.system(.caption, weight: .semibold))
                    }
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if suggestions.isEmpty {
                // Loading; if the directory can't be read, See All above is
                // still the way in.
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: Self.cardWidth * 9 / 16 + 44)
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.snug) {
                    ForEach(suggestions) { row in
                        // A press starts it: the mini shelf is the quick way in.
                        ActivityGridCard(
                            row: row,
                            onOpen: { launch(row.id) },
                            onStart: nil,
                            artWidth: Self.cardWidth * 2
                        )
                        .frame(width: Self.cardWidth)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(Spacing.margin)
        .frame(width: Self.cardWidth * 3 + Spacing.snug * 2 + Spacing.margin * 2)
        .animation(.easeOut(duration: 0.2), value: suggestions.map(\.id))
        .task {
            await model.sessionController.loadActivityDirectory()
            isLoading = false
        }
    }

    private func launch(_ id: ApplicationID) {
        guard let app = model.activityApp(id) else { return }
        dismiss()
        Task { await model.sessionController.launchActivity(app, in: channelID, section: nil) }
    }
}

private struct ActivityArtTile: View {
    var row: ActivityRow
    var size: CGSize
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            RemoteImage(url: row.tileURL, side: Metrics.activityTileWidth, bucket: .artwork) {
                ActivityIcon(row: row, side: Metrics.activityRowIcon)
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .scaleEffect(isHovered ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .help(row.name)
        .accessibilityLabel(Text(row.name))
        .accessibilityHint(Text(row.subtitle))
    }
}
