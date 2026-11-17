import SwiftUI
import WingcordCore

/// A Spotify link's card, redrawn (Alex, 2026-11-17: "redesign the spotify
/// song link embed … i want smth cool beautiful"): Spotify's own embed's
/// arrangement in this app's materials. The artwork's colour is the card's
/// ground, deepening to near-black; big artwork; the name and who made it; a
/// round Play that runs the thirty-second preview, with its progress along the
/// foot; Spotify's mark, which opens Spotify's own player for the whole track.
struct SpotifyLinkCard: View {
    var key: SpotifyCardKey

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var anchor = WindowAnchorBox()

    /// One height for every kind: the artwork's, and the padding around it.
    static let height: CGFloat = 132
    private static let art: CGFloat = 100
    private static let corner: CGFloat = 16

    var body: some View {
        if let card = model.spotifyUnfurls[key.unfurlKey] {
            content(card)
        }
    }

    private func content(_ card: SpotifyUnfurl) -> some View {
        let isPlaying = card.previewURL != nil && model.spotifyPreview.playing == card.previewURL
        return HStack(alignment: .center, spacing: Spacing.snug) {
            RemoteImage(url: card.coverURL, side: Self.art, bucket: .artwork) {
                Color.white.opacity(0.08)
            }
            .frame(width: Self.art, height: Self.art)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: Spacing.tight) {
                    if card.isExplicit {
                        Text("E")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.8))
                            .frame(width: 15, height: 15)
                            .background(.white.opacity(0.75), in: .rect(cornerRadius: 3))
                            .accessibilityLabel(Text("Explicit"))
                    }
                    if let subtitle = card.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(.callout, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text([card.kind.label, card.durationLabel].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
            }
            .frame(maxHeight: Self.art)

            Spacer(minLength: 0)

            if let preview = card.previewURL {
                Button {
                    model.voicePlayer.pause()
                    model.spotifyPreview.toggle(preview)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.black)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: 48)
                        .background(.white, in: .circle)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .scaleEffect(isHovering && !motion.reduceMotion ? 1.04 : 1)
                .help(isPlaying ? "Pause the preview" : "Play a 30-second preview")
                .accessibilityLabel(Text(isPlaying ? "Pause preview" : "Play preview"))
            }
        }
        .padding(Spacing.snug + 2)
        .frame(height: Self.height)
        .background { ground(card) }
        .overlay(alignment: .topTrailing) { spotifyMark(card) }
        .overlay(alignment: .bottom) {
            if isPlaying { progress }
        }
        .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .background { WindowAnchorProbe(box: anchor) }
        .onHover { isHovering = $0 }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: isPlaying)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(card.title)\(card.subtitle.map { ", \($0)" } ?? "") on Spotify"))
    }

    /// The artwork's colour, deepening toward the foot as Spotify's embed's
    /// does; the brand's dark grey where Spotify sent none.
    private func ground(_ card: SpotifyUnfurl) -> some View {
        let base = card.accentValue.map { Color(hex: $0) } ?? Color(red: 0.16, green: 0.16, blue: 0.16)
        return LinearGradient(
            colors: [base.mix(with: .black, by: 0.25), base.mix(with: .black, by: 0.62)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Spotify's mark: the way into Spotify's own player, for the whole track.
    private func spotifyMark(_ card: SpotifyUnfurl) -> some View {
        Button {
            model.openSpotifyPlayer(card, anchor: anchor.rectInWindowRoot())
        } label: {
            BrandGlyph(service: "spotify")
                .fill(.white)
                .frame(width: 20, height: 20)
                .padding(Spacing.base)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open in Spotify\u{2019}s player")
        .accessibilityLabel(Text("Open in Spotify"))
    }

    /// The preview's place, along the card's foot.
    private var progress: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let fraction = min(1, model.spotifyPreview.elapsed() / model.spotifyPreview.length())
            GeometryReader { proxy in
                Capsule()
                    .fill(.white)
                    .frame(width: max(4, proxy.size.width * fraction), height: 3)
            }
            .frame(height: 3)
            .background(Capsule().fill(.white.opacity(0.2)))
        }
        .padding(.horizontal, Spacing.snug + 2)
        .padding(.bottom, 6)
        .transition(.opacity)
    }
}
