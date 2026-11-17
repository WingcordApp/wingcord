import SwiftUI
import WingcordCore

/// A featured app as a cover card (decision 5): its artwork full bleed, the
/// name and line over a dimmed foot, and Discord's preview loop playing while
/// the pointer rests on it. In a call, a Start button rides the corner.
///
/// **Content, not glass** (HIG: Liquid Glass is for the controls floating over
/// content): the card is artwork on the panel; only its Start button is glass.
struct ActivityFeatureCard: View {
    var row: ActivityRow
    /// The first featured app, drawn across the panel.
    var isHero = false
    var onOpen: () -> Void
    /// Starts it in the call; nil where cards only open the app's page.
    var onStart: (() -> Void)?

    @Environment(\.motion) private var motion
    @State private var isHovered = false
    @State private var settings = AppSettings.shared

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(isHero ? 2.1 : 16 / 9, contentMode: .fit)
                .overlay { art }
                .overlay(alignment: .bottomLeading) { caption }
                .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
                .contentShape(.rect(cornerRadius: Radius.glass, style: .continuous))
                .scaleEffect(isHovered ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let onStart, isHovered || isHero {
                Button("Start", systemImage: "play.fill", action: onStart)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Palette.accent)
                    .padding(Spacing.base)
                    .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(row.name)
        .accessibilityHint(row.subtitle)
    }

    private var art: some View {
        RemoteImage(url: row.tileURL, side: isHero ? 600 : Metrics.activityTileWidth * 2, bucket: .artwork) {
            ZStack {
                Palette.surfaceRaised
                ActivityIcon(row: row, side: Metrics.activityHeaderIcon)
            }
        }
        .aspectRatio(contentMode: .fill)
        .overlay {
            // The preview loop, only while hovered (one player at a time
            // across the panel) and only where moving pictures are allowed.
            if isHovered, let video = row.previewVideoURL, settings.playsAnimatedMedia, !motion.reduceMotion {
                LoopingVideo(url: video)
                    .transition(.opacity)
            }
        }
    }

    /// The name over a dimmed foot: legible on any artwork.
    private var caption: some View {
        HStack(spacing: Spacing.base) {
            ActivityIcon(row: row, side: isHero ? 36 : 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name)
                    .font(.system(isHero ? .title3 : .subheadline, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
        }
    }
}
