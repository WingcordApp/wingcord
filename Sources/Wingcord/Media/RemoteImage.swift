import SwiftUI
import WingcordCore

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
    /// Repeats the picture down and across its frame, each copy this many
    /// points wide — a profile frame's `border`. Nil stretches it to the
    /// frame, which is every other caller.
    var tileWidth: CGFloat? = nil
    /// How a picture that lands after the placeholder was drawn comes in. Nil
    /// swaps it, which is right for a row; one already in memory is drawn on
    /// the first frame either way.
    var arrival: Animation? = nil
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
        let resolved = resolved
        Group {
            if let resolved {
                image(resolved)
            } else {
                placeholder
            }
        }
        .animation(arrival, value: resolved == nil)
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

extension RemoteImage {
    private func image(_ decoded: CGImage) -> Image {
        if let tileWidth, tileWidth > 0 {
            // The copy's width in points is the decode's in pixels over this
            // scale — so the scale is what makes one copy `tileWidth` wide.
            return Image(decorative: decoded, scale: CGFloat(decoded.width) / tileWidth)
                .resizable(resizingMode: .tile)
        }
        return Image(decorative: decoded, scale: displayScale).resizable()
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
    /// Whether an animated avatar plays here.
    ///
    /// **Off by default, and the default is not laziness.** A roster of two
    /// hundred people or a channel of four hundred messages carries dozens of
    /// GIF faces, and playing them all is dozens of filmstrips resident and
    /// dozens of layers rewritten every tick for pictures nobody is looking at —
    /// which is why those surfaces play only the row under the pointer, through
    /// `HoverAvatarFilm`.
    ///
    /// A profile card is the opposite case: **one** face, opened deliberately,
    /// and the thing the reader came to look at. It plays whenever it can.
    var animates = false

    @Environment(\.motion) private var motion
    /// The reader's own animation preference. Its label names avatars, so it
    /// governs this directly.
    @State private var settings = AppSettings.shared

    /// Whether the still under the moving face has been taken away.
    ///
    /// The same latch the decoration below keeps, and for the same reason: two
    /// copies of one picture, decoded by different paths at different sizes,
    /// read as a rendering fault rather than as a face.
    @State private var faceIsPlaying = false

    /// **Both answers, resolved together** — `INVARIANTS.md`'s rule: the
    /// reader's battery switch and the system's Reduce Motion. Honouring one and
    /// not the other is how somebody who turned animation off gets it anyway.
    ///
    /// `CDN.canAnimate` is the third: an avatar hash without `a_` is served as
    /// PNG, and asking for a filmstrip there costs a multi-frame decode to
    /// discover there is one frame.
    private var playsFace: Bool {
        guard animates, let url, CDN.canAnimate(url) else { return false }
        // Game Mode's animated-emoji override reaches avatars too: they are
        // the same frames on the same clock.
        return settings.playsAnimatedContent && !motion.reduceMotion && !GameMode.shared.isThrottling
    }

    /// Whether the still under the moving decoration has been taken away.
    ///
    /// See the comment on the overlay: this is the whole of the doubled-rim
    /// defect, and it is state rather than a derived value because only
    /// `AnimatedDecoration` knows whether there are frames on screen.
    @State private var decorationIsPlaying = false

    var body: some View {
        ZStack {
            RemoteImage(url: url, side: side) {
                Text(monogram)
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: side, height: side)
                    // Neutral. A person's colour is their avatar, never a tint
                    // derived from their name.
                    .background(Palette.surfaceRaised)
            }
            // The still goes when the film is up — see `faceIsPlaying`.
            //
            // **`&& playsFace`, and the second half is not redundant.** The
            // latch is `@State` and only the film can clear it; if the film
            // stops being built for any reason the report never comes, the
            // latch stays true and the still stays hidden — an avatar that is
            // simply *gone*. `onChange(of: url)` covers a changed face, but not
            // the reader turning animation off, Reduce Motion arriving, or the
            // view being rebuilt around a resize. Asking whether there is a film
            // at all cannot get stuck.
            .opacity(faceIsPlaying && playsFace ? 0 : 1)

            if playsFace, let url {
                // **`.resizeAspectFill`, unlike a decoration's.** An avatar is
                // cropped to its circle and must cover it; a decoration is
                // drawn around one and must not be cropped at all.
                AnimatedDecoration(
                    url: url,
                    side: side,
                    gravity: .resizeAspectFill,
                    onPlayback: { playing in
                        guard faceIsPlaying != playing else { return }
                        faceIsPlaying = playing
                    }
                )
                .frame(width: side, height: side)
                .allowsHitTesting(false)
            }
        }
        // A face that changes has to put its still back while the new one
        // resolves, or the avatar is empty in between.
        .onChange(of: url) { faceIsPlaying = false }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .overlay {
            if let decorationURL {
                // **Two layers, and the still one is taken away once the film
                // is up.**
                //
                // Discord serves decorations as APNG, and most of them animate —
                // but not all, and the filmstrip takes a fetch and a multi-frame
                // decode to discover which. The still underneath draws on the
                // first frame from the ordinary image cache; the animated layer
                // above it stays empty until it has something real to show, and
                // stays empty forever for an asset that turns out to be a single
                // frame. So a decoration is never missing while it resolves, and
                // a still one costs no clock subscription at all.
                //
                // **`onPlayback` is what stops it being two copies.** The two
                // layers are decoded by different paths at different sizes, so
                // an asset with a soft or transparent rim — a cat's ear, a
                // feathered halo — shows the still as a second, offset outline
                // behind the moving one. It is unmistakable once seen and easy
                // to read as a rendering fault in the artwork. `GuildRailTile`
                // and `NameplateArtwork` have always done this; this call site
                // never did, which is why it was the one place the doubling was
                // visible. The report is deferred and generation-guarded inside
                // `AnimatedDecoration` — `INVARIANTS.md` §1, "A representable
                // NEVER reports state from `updateNSView`".
                ZStack {
                    RemoteImage(url: decorationURL, side: side * Metrics.decorationScale) {
                        Color.clear
                    }
                    .opacity(decorationIsPlaying ? 0 : 1)
                    AnimatedDecoration(
                        url: decorationURL,
                        side: side * Metrics.decorationScale,
                        onPlayback: { playing in
                            guard decorationIsPlaying != playing else { return }
                            decorationIsPlaying = playing
                        }
                    )
                }
                // A decoration that changes has to put its still back while the
                // new one resolves, or the avatar wears nothing in between.
                .onChange(of: decorationURL) { decorationIsPlaying = false }
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
