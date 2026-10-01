import SwiftUI
import WingcordCore

/// A small picture that plays where it can move — an emoji in a strip, a
/// server's icon — and holds still everywhere else.
///
/// **`AvatarView`'s arrangement, for pictures that are not faces**: the still
/// from the image store underneath, the film over it, and the still taken away
/// once the film reports frames — two copies of one picture decoded by
/// different paths read as a rendering fault, not as the picture.
///
/// **Gated on the address and the reader**, as every animated surface here
/// is: `CDN.canAnimate` says whether the asset moves at all (an animated emoji
/// or icon is served as `.gif`, a still one as `.webp`), and
/// `AnimationClock.playsAnimatedEmoji` is the reader's switch and Reduce
/// Motion together.
struct AnimatedPicture<Placeholder: View>: View {
    var url: URL?
    var side: CGFloat
    var bucket: ImageStore.Bucket = .thumbnail
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: Placeholder

    @Environment(\.motion) private var motion
    @State private var isPlaying = false

    /// Whether there is a moving form to put up at all.
    ///
    /// **Read beside the latch, and that is what stops it sticking** — the
    /// expression card's lesson: only the film can clear `isPlaying`, so a
    /// film that goes away for any reason must not leave the still hidden.
    private var plays: Bool {
        guard let url, CDN.canAnimate(url) else { return false }
        return AnimationClock.playsAnimatedEmoji
    }

    var body: some View {
        ZStack {
            RemoteImage(url: url, side: side, bucket: bucket) { placeholder }
                .aspectRatio(contentMode: contentMode)
                .opacity(isPlaying && plays ? 0 : 1)
                .animation(motion.fadeQuick, value: isPlaying)
            if plays, let url {
                AnimatedDecoration(
                    url: url,
                    side: side,
                    gravity: contentMode == .fill ? .resizeAspectFill : .resizeAspect,
                    onPlayback: { playing in
                        guard isPlaying != playing else { return }
                        isPlaying = playing
                    }
                )
                .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        // A different picture puts its still back while the new one resolves.
        .onChange(of: url) { isPlaying = false }
    }
}
