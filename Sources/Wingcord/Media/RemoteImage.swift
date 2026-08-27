import SwiftUI

/// A remote image sized at both ends: the CDN rung asked for, and the pixel size
/// decoded to.
///
/// **The cached case must not cost a frame.** `ImageStore.cached` is a
/// synchronous, non-isolated peek, read during body evaluation — so an image
/// already in memory draws on the first frame rather than drawing a placeholder,
/// hopping an actor, and re-rendering. One hop per row, times a roster, is a
/// second layout pass for nothing.
///
/// **The latch is the resolved URL, not a `Bool`.** `@State` survives a
/// `.task(id:)` restart — the view keeps its identity, only the task is
/// replaced — so a row repointed at a different person must fall back to peeking
/// for the *new* URL. A boolean "already looked" latch leaves the previous
/// person's picture on screen under the new person's name.
struct RemoteImage<Placeholder: View>: View {
    var url: URL?
    /// The side this will be drawn at, in points. Decides the decode size.
    var side: CGFloat
    var bucket: ImageStore.Bucket = .thumbnail
    @ViewBuilder var placeholder: Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var decoded: CGImage?
    /// The URL `decoded` belongs to. See the note above.
    @State private var decodedURL: URL?

    private var pixelSize: Int {
        Int((side * max(displayScale, 1)).rounded(.up))
    }

    private var key: ImageStore.Key? {
        url.map { ImageStore.Key(url: $0, maximumPixelSize: pixelSize) }
    }

    /// The image to draw this frame: the state if it belongs to the current URL,
    /// otherwise a synchronous peek, otherwise nothing.
    private var resolved: CGImage? {
        if let decoded, decodedURL == url { return decoded }
        guard let key else { return nil }
        if let url, LottieFilmstrip.handles(url) {
            return AnimatedImageStore.shared.cached(filmKey(for: key))?.frames.first
        }
        return ImageStore.shared.cached(key, bucket: bucket)
    }

    /// Lottie's slot in the filmstrip cache.
    ///
    /// **A vector animation has no still anywhere**: `CGImageSource` cannot open
    /// it and the CDN serves no bitmap for it, so the only way to draw one at
    /// all is to rasterise it and take a frame. Its first frame is the poster,
    /// which is what a badge or a row thumbnail wants — the strip it comes from
    /// is a few kilobytes at these sizes, and nothing here subscribes to a clock
    /// for it.
    private func filmKey(for key: ImageStore.Key) -> AnimatedImageStore.Key {
        AnimatedImageStore.Key(url: key.url, maximumPixelSize: key.maximumPixelSize)
    }

    var body: some View {
        Group {
            if let resolved {
                Image(decorative: resolved, scale: displayScale)
                    .resizable()
            } else {
                placeholder
            }
        }
        .task(id: key) {
            guard let key else {
                decoded = nil
                decodedURL = nil
                return
            }
            // Synchronously, before any await: a row that has been repointed
            // must not keep showing the previous subject while the new fetch is
            // in flight.
            let isLottie = LottieFilmstrip.handles(key.url)
            if decodedURL != key.url {
                decoded = isLottie
                    ? AnimatedImageStore.shared.cached(filmKey(for: key))?.frames.first
                    : ImageStore.shared.cached(key, bucket: bucket)
                decodedURL = decoded == nil ? nil : key.url
            }
            guard decoded == nil else { return }

            let image = isLottie
                ? await AnimatedImageStore.shared.image(for: filmKey(for: key))?.frames.first
                : await ImageStore.shared.image(for: key, bucket: bucket)
            // A cancelled task can still resume and write a stale answer into
            // shared state, so the id is re-checked after the await.
            guard !Task.isCancelled, key.url == url else { return }
            decoded = image
            decodedURL = image == nil ? nil : key.url
        }
    }
}

/// A circular avatar with a monogram fallback.
///
/// Its own type rather than a `RemoteImage` with modifiers at each call site,
/// because the fallback, the clip and the decode size have to agree and there
/// are a hundred call sites to disagree at.
struct AvatarView: View {
    var url: URL?
    var monogram: String
    var side: CGFloat
    /// Drawn *around* the avatar at 1.2x and outside its circular mask, so it
    /// contributes no layout size — an overlay is sized to what it decorates.
    var decorationURL: URL?

    var body: some View {
        RemoteImage(url: url, side: side) {
            Text(monogram)
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: side, height: side)
                // Neutral. A person's colour is their avatar, never a tint
                // derived from their name.
                .background(Palette.surfaceRaised)
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .overlay {
            if let decorationURL {
                // **Two layers, and the still one is not wasted.**
                //
                // Discord serves decorations as APNG, and most of them animate —
                // but not all, and the filmstrip takes a fetch and a multi-frame
                // decode to discover which. The still underneath draws on the
                // first frame from the ordinary image cache; the animated layer
                // above it stays empty until it has something real to show, and
                // stays empty forever for an asset that turns out to be a single
                // frame. So a decoration is never missing while it resolves, and
                // a still one costs no clock subscription at all.
                ZStack {
                    RemoteImage(url: decorationURL, side: side * Metrics.decorationScale) {
                        Color.clear
                    }
                    AnimatedDecoration(
                        url: decorationURL,
                        side: side * Metrics.decorationScale
                    )
                }
                .frame(
                    width: side * Metrics.decorationScale,
                    height: side * Metrics.decorationScale
                )
                .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}
