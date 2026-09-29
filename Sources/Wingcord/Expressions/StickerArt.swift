import SwiftUI
import WingcordCore

/// One sticker, at any size, moving if it moves.
///
/// **Each format goes to the thing that plays it best.** A Lottie sticker is a
/// vector animation and plays on the render server — see `LottieSticker`. APNG
/// and GIF are frames, and play as the still under its own moving copy, the
/// arrangement the rest of the app uses: `onPlayback` takes the still away once
/// the film has frames, so an asset with a soft rim is never two offset copies.
struct StickerArt: View {
    var sticker: StickerRef
    var side: CGFloat

    /// Whether the still under the moving copy has been taken away.
    @State private var isPlaying = false

    private var url: URL? { CDN.sticker(id: sticker.id, format: sticker.format) }

    var body: some View {
        Group {
            if sticker.format == .lottie, let url {
                LottieSticker(url: url)
            } else {
                RemoteImage(url: url, side: side, bucket: .artwork) { Color.clear }
                    .aspectRatio(contentMode: .fit)
                    .opacity(isPlaying ? 0 : 1)
                    .overlay {
                        if sticker.format.isAnimated, let url {
                            AnimatedDecoration(
                                url: url,
                                side: side,
                                onPlayback: { playing in
                                    // A `@State` write of an equal value still
                                    // invalidates.
                                    guard isPlaying != playing else { return }
                                    isPlaying = playing
                                }
                            )
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sticker, \(sticker.name)")
    }
}
