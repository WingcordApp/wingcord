import SwiftUI
import WingcordCore

// MARK: - Clips, over the game
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D20) — Discord's clips in the overlay
// (`2026-06-clips-secondary-entrypoints`). Two states, because the overlay
// has two:
//
//   * **asleep** — what the clip key just did, and nothing else: a toast that
//     comes and goes, pinned so it is seen while playing;
//   * **open** — Save Clip and Screenshot as buttons with their keys beside
//     them, the last three things saved (a click opens one in the editor), and
//     the same line about the last save.

struct OverlayClipsWidget: View {
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var recent: [Clip] = []

    static let width: CGFloat = 300

    var body: some View {
        if controller.isLocked {
            feedback
        } else {
            panel
        }
    }

    // MARK: Asleep

    @ViewBuilder private var feedback: some View {
        if let state = controller.clipFeedback {
            feedbackLine(state)
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.base)
                .frame(maxWidth: 280, alignment: .leading)
                .chromeOverMedia(in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(motion.standard, value: state)
                .accessibilityElement(children: .combine)
        }
    }

    private func feedbackLine(_ state: ClipFeedback) -> some View {
        HStack(spacing: Spacing.base) {
            Image(symbol: state.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.isFailure ? Palette.destructive : Palette.presenceOnline)
            Text(state.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
        }
    }

    // MARK: Open

    private var panel: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack {
                Text("CLIPS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
                Button("Library") { ClipsWindow.open() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
            HStack(spacing: Spacing.base) {
                action("Save Clip", symbol: "film.stack", key: .saveClip) { model.saveClip() }
                    .disabled(!AppSettings.shared.clipsEnabled)
                action("Screenshot", symbol: "camera", key: .saveScreenshot) { model.saveScreenshot() }
            }
            if !AppSettings.shared.clipsEnabled {
                Text("Clips is off — turn it on in Settings › Clips to keep the last moments.")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recent.isEmpty {
                HStack(spacing: Spacing.base) {
                    ForEach(recent) { clip in
                        RecentClipThumbnail(clip: clip)
                    }
                }
            }
            if let state = controller.clipFeedback {
                feedbackLine(state)
                    .transition(.opacity)
            }
        }
        .padding(Spacing.snug)
        .frame(width: Self.width, alignment: .leading)
        .background(Palette.canvas, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.relative(dark: 0.10, light: 0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .animation(motion.standard, value: controller.clipFeedback)
        .task(id: model.clipsRevision) {
            recent = Array(ClipLibrary.contents().prefix(3))
        }
    }

    private func action(
        _ title: String, symbol: String, key: GlobalAction, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: 2) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .semibold))
                if let keys = AppSettings.shared.hotkey(for: key)?.displayString {
                    Text(keys)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// One saved thing, small. A click opens it in the editor.
private struct RecentClipThumbnail: View {
    var clip: Clip
    @State private var picture: CGImage?

    private var kind: ClipLibraryItem.Kind {
        clip.isScreenshot ? .screenshot : clip.isRecording ? .recording : .clip
    }

    var body: some View {
        Button {
            ClipsWindow.open(editing: clip.url)
        } label: {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Ink.primary.opacity(0.08))
                if let picture {
                    Image(decorative: picture, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                Image(systemName: clip.isScreenshot ? "photo" : "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.5), in: .circle)
                    .padding(4)
            }
            .frame(width: 84, height: 48)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(clip.name)
        .accessibilityLabel(clip.name)
        .task(id: clip.url) {
            picture = await ClipThumbnails.shared.thumbnail(for: clip.url, kind: kind)
        }
    }
}
