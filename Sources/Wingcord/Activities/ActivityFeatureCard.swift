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
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                        .strokeBorder(Palette.edge, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    // Discord's badge for a sponsored app (Alex, 2026-11-18).
                    if row.isPromoted { PromotedBadge().padding(Spacing.snug) }
                }
                .contentShape(.rect(cornerRadius: Radius.glass, style: .continuous))
                .scaleEffect(isHovered && !motion.reduceMotion ? 1.012 : 1)
                .shadow(
                    color: .black.opacity(isHovered ? 0.34 : 0.2),
                    radius: isHovered ? 18 : 8,
                    y: isHovered ? 9 : 4
                )
        }
        .buttonStyle(ActivityPressStyle())
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
            ActivityArtFallback(row: row)
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
            ActivityIcon(row: row, side: isHero ? 44 : 28)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(isHero ? .title2 : .subheadline, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.system(isHero ? .subheadline : .caption, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isHero ? Spacing.margin : Spacing.snug)
        .padding(.top, isHero ? Spacing.margin * 2 : Spacing.margin)
        .padding(.bottom, isHero ? Spacing.margin : Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // **A long, eased fade**, so the words sit on the art rather than
            // on a band laid over it: nothing, then a breath, then deep.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.32), location: 0.45),
                    .init(color: .black.opacity(0.78), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
