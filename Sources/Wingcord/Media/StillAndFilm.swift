import SwiftUI

/// A picture's still with its moving form over it, the still stepping aside
/// once the film has frames up — so the two never show at once through a
/// transparent edge, which reads as a ghost of the first frame under every
/// other one (a Lottie sticker's poster under its vectors, most of all).
///
/// The same latch `AvatarView` keeps for a face, for the pickers' smaller
/// pictures: a pack's emoji, the hover row's art.
struct StillAndFilm<Placeholder: View>: View {
    var url: URL?
    var side: CGFloat
    /// Whether this one may move here — animated, and allowed to be.
    var plays: Bool
    @ViewBuilder var placeholder: () -> Placeholder

    /// Whether the film has frames up, so the still under it can go.
    @State private var isFilmUp = false

    var body: some View {
        ZStack {
            RemoteImage(url: url, side: side, placeholder: placeholder)
                // `&& plays`: a film that stops being built never reports, and
                // the still must not stay hidden behind nothing.
                .opacity(isFilmUp && plays ? 0 : 1)
            if plays, let url {
                AnimatedDecoration(url: url, side: side, onPlayback: { playing in
                    guard isFilmUp != playing else { return }
                    isFilmUp = playing
                })
                .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .onChange(of: url) { isFilmUp = false }
    }
}
