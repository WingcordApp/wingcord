import SwiftUI
import WingcordCore

// MARK: - Activities in a call
//
// Discord's two ways into an activity from inside a call, both reading the
// shelf's own ranking (`AppModel.suggestedActivities`):
//
// - **the call's Activities control**, which opens its "Activities Mini
//   Shelf": "Suggested Activities", "See All ›", and the top five. See All
//   opens the full launcher — Search, Recents, Activities — in the same panel,
//   so nothing nests;
// - **the suggestion under a server's call** — its
//   `VC_TILE_ACTIVITIES_ENTRY_POINT`: "Looking for something to do? Start a
//   game or video playlist instantly.", the top three at 16:9, and "Don't show
//   again".
//
// A tile launches into the call through the launcher's own path.

/// The Activities control's panel.
struct ActivitiesShelfPanel: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsLauncher = false
    @State private var isLoading = true

    /// The shelf's tiles: Discord's cover art, wide.
    private static let tile = CGSize(width: 160, height: 90)

    var body: some View {
        Group {
            if showsLauncher {
                ActivityLauncher(channelID: channelID)
            } else {
                shelf
            }
        }
        .task {
            await model.sessionController.loadActivityDirectory()
            isLoading = false
        }
    }

    private var shelf: some View {
        let suggestions = model.suggestedActivities(5)
        return VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(Ink.primary)
                Text("Suggested Activities")
                    .textCase(.uppercase)
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Spacing.margin)
                Button {
                    model.activityLauncherPage = .directory
                    showsLauncher = true
                } label: {
                    HStack(spacing: 2) {
                        Text("See All").textCase(.uppercase)
                        Image(systemName: "chevron.right")
                    }
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(Ink.primary)
                }
                .buttonStyle(.plain)
            }
            if suggestions.isEmpty {
                // Loading; and if the directory could not be read, See All
                // above is still the way in.
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: Self.tile.height)
                }
            } else {
                HStack(spacing: Spacing.snug) {
                    ForEach(suggestions) { row in
                        ActivityArtTile(row: row, size: Self.tile) { launch(row.id) }
                    }
                }
            }
        }
        .padding(Spacing.margin)
    }

    private func launch(_ id: ApplicationID) {
        guard let app = model.activityApp(id) else { return }
        dismiss()
        Task { await model.sessionController.launchActivity(app, in: channelID, section: nil) }
    }
}

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
        Task { await model.sessionController.launchActivity(app, in: channelID, section: nil) }
    }
}

/// An activity's cover art as a tile, its name for VoiceOver and the pointer.
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
