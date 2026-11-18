import SwiftUI
import WingcordCore

// MARK: - The Showcase launcher's parts
//
// Alex, 2026-11-18, picked over a list and a gallery: the launcher reads like
// the App Store's Today — big icons for what you've played, a paging carousel
// of wide hero cards, then each collection as a grid of cards with the
// artwork above and the app below. The Suggested Activities flyout is the
// same cards, three across. See `ActivitySectionView`.

/// Discord's PROMOTED pill for a sponsored app (`ApplicationFlags.PROMOTED`):
/// white with dark letters, so it reads on any artwork.
struct PromotedBadge: View {
    var body: some View {
        Text("PROMOTED")
            .font(.system(size: 10, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Color.white.opacity(0.94), in: .capsule)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .accessibilityLabel(Text("Promoted"))
    }
}

/// A card's answer to a press: it gives a little on pointer-down, the moment
/// the click lands, and springs back — never on release, which feels late.
struct ActivityPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        var configuration: Configuration
        @Environment(\.motion) private var motion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !motion.reduceMotion ? 0.97 : 1)
                .animation(.spring(response: 0.24, dampingFraction: 0.8), value: configuration.isPressed)
        }
    }
}

/// An app as a card in a collection: its artwork above, rounded and lifted
/// on hover with its preview playing, and the app below — icon, name, line.
///
/// **Content, not glass** (HIG: Liquid Glass is for controls floating over
/// content). Only the Start button that appears over the art in a call is
/// glass.
struct ActivityGridCard: View {
    var row: ActivityRow
    var onOpen: () -> Void
    /// Starts it in the call; nil where a card opens the app's page.
    var onStart: (() -> Void)?
    /// How wide the artwork is decoded, in points.
    var artWidth: CGFloat = Metrics.activityTileWidth * 2

    @Environment(\.motion) private var motion
    @State private var isHovered = false
    @State private var settings = AppSettings.shared

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                art
                HStack(alignment: .center, spacing: Spacing.base) {
                    ActivityIcon(row: row, side: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.hair)
            }
            .contentShape(.rect)
        }
        .buttonStyle(ActivityPressStyle())
        .overlay(alignment: .topTrailing) {
            if let onStart, isHovered {
                Button("Start", systemImage: "play.fill", action: onStart)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Palette.accent)
                    .padding(Spacing.base)
                    .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(row.isPromoted ? "\(row.name), promoted" : row.name)
        .accessibilityHint(row.subtitle)
    }

    private var art: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                RemoteImage(url: row.tileURL, side: artWidth, bucket: .artwork) {
                    ActivityArtFallback(row: row)
                }
                .aspectRatio(contentMode: .fill)
                .overlay {
                    if isHovered, let video = row.previewVideoURL, settings.playsAnimatedMedia, !motion.reduceMotion {
                        LoopingVideo(url: video)
                            .transition(.opacity)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .strokeBorder(Palette.edge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if row.isPromoted {
                    PromotedBadge().padding(Spacing.base)
                }
            }
            .scaleEffect(isHovered && !motion.reduceMotion ? 1.02 : 1)
            .shadow(
                color: .black.opacity(isHovered ? 0.32 : 0.18),
                radius: isHovered ? 14 : 6,
                y: isHovered ? 7 : 3
            )
    }
}

/// An app with no artwork of its own: its icon, large and blurred into a
/// ground of its own colours, with the crisp icon on top — never a grey box.
struct ActivityArtFallback: View {
    var row: ActivityRow

    var body: some View {
        ZStack {
            Palette.surfaceRaised
            RemoteImage(url: row.iconURL, side: 64) { Color.clear }
                .aspectRatio(contentMode: .fill)
                .scaleEffect(1.6)
                .blur(radius: 28)
                .saturation(1.3)
                .opacity(0.85)
            ActivityIcon(row: row, side: Metrics.activityHeaderIcon)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .clipped()
    }
}

/// The featured collection as a paging carousel of wide hero cards, with the
/// page it is on shown as dots under it — a dot takes you to its page.
struct ActivityHeroCarousel: View {
    var rows: [ActivityRow]
    var onOpen: (ActivityRow) -> Void
    var onStart: ((ActivityRow) -> Void)?

    @Environment(\.motion) private var motion
    @State private var current: ApplicationID?

    var body: some View {
        VStack(spacing: Spacing.base) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: Spacing.snug) {
                    ForEach(rows) { row in
                        ActivityFeatureCard(
                            row: row,
                            isHero: true,
                            onOpen: { onOpen(row) },
                            onStart: start(row)
                        )
                        .containerRelativeFrame(.horizontal)
                        .id(row.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $current)
            .scrollIndicators(.never)

            if rows.count > 1 { dots }
        }
    }

    private var dots: some View {
        let shown = current ?? rows.first?.id
        return HStack(spacing: 6) {
            ForEach(rows) { row in
                let isCurrent = row.id == shown
                Capsule()
                    .fill(isCurrent ? Ink.primary : Ink.quaternary)
                    .frame(width: isCurrent ? 18 : 6, height: 6)
                    .contentShape(.rect.inset(by: -4))
                    .onTapGesture {
                        withAnimation(motion.reduceMotion ? nil : motion.reposition) { current = row.id }
                    }
                    .accessibilityLabel(Text(row.name))
                    .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            }
        }
        .animation(motion.standard, value: shown)
        .frame(maxWidth: .infinity)
    }

    private func start(_ row: ActivityRow) -> (() -> Void)? {
        guard let onStart, row.isLaunchable else { return nil }
        return { onStart(row) }
    }
}
