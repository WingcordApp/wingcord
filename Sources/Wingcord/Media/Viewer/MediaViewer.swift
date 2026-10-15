import SwiftUI

/// The lightbox: a message's pictures, clips and animations, one at a time, at
/// the size the window can give them — opened out of the thumbnail that was
/// clicked and closed back into it (REDESIGN.md D8), paged through as a gallery
/// (D9).
///
/// **One surface for all three kinds, with three sets of controls.** What a
/// reader does with a photograph and with a video have almost nothing in
/// common — one zooms, the other scrubs — so the bar under the stage is built
/// from the kind and only the top bar is shared.
///
/// **The viewer animates itself in and out** rather than leaving it to a
/// transition: the picture's flight is the arrival and the departure, and the
/// scrim follows it (`MediaStageController.presence`), so the two are one
/// movement rather than a fade beside a flight. The chrome waits for the
/// landing (`MediaViewerChrome.isShown`). The viewer is taken off the window
/// only once the picture has landed back in its box.
struct MediaViewer: View {
    var request: MediaViewerRequest
    /// One picture along, wrapping — the arrows, the chevrons, a swipe.
    var step: (Int) -> Void
    /// One picture by its place — the gallery strip.
    var show: (Int) -> Void
    /// Takes the viewer off the window at once. Called when the flight home
    /// has landed, never before.
    var dismiss: () -> Void

    @State private var stage = MediaStageController()
    @State private var playback = VideoPlayback()
    @State private var actions = MediaActions()
    /// The strip's pick while the page slides to it.
    @State private var jumpTarget: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            MediaBackdrop(stage: stage)

            if let item = request.current {
                MediaStage(
                    item: item,
                    previous: request.item(offsetBy: -1),
                    next: request.item(offsetBy: 1),
                    controller: stage,
                    player: item.isVideo ? playback.player : nil,
                    home: thumbnail,
                    onRequestClose: { close(velocity: $0) },
                    onPage: paged,
                    onContentClick: playback.togglePlayback
                )
                // **The stage runs to the window's edges, every kind.** A
                // video keeps clear of the chrome inside the canvas
                // (`letterboxInsets`) rather than by a frame out here, so
                // paging between a photograph and a clip never re-lays the
                // stage under a moving page.
                .ignoresSafeArea()
                .accessibilityLabel(Text(item.altText ?? item.filename))

                MediaViewerChrome(
                    request: request,
                    stage: stage,
                    playback: playback,
                    actions: actions,
                    page: { stage.page(by: $0) },
                    jump: jump,
                    close: { close() }
                )
            }
        }
        // The viewer takes the keyboard while it is up: Escape closes, the
        // arrows do what the kind on screen says they do, and space is the
        // universal "act on this".
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            stage.onClosed = finish
            lift()
        }
        .onExitCommand { close() }
        .onKeyPress(action: handle(key:))
        // The picture on stage is out of its box; the one paged away from goes
        // back into its own.
        .onChange(of: request.index) { lift() }
        // Loading is keyed on the item, so stepping swaps what the player
        // holds instead of building a second one.
        .task(id: request.current?.id) {
            let item = request.current
            playback.load(
                url: item?.isVideo == true ? item?.sourceURL : nil,
                identity: item?.id.rawValue,
                autoplay: true
            )
        }
        // Only the player. A save in flight is left to finish — see
        // `MediaActions.save`.
        .onDisappear {
            playback.tearDown()
            MediaSources.shared.lift(nil, origin: request.origin)
        }
    }

    // MARK: The thumbnail

    /// Where the picture on stage sits in the surface it came from — asked as
    /// the stage opens and again as it closes, because the reader may have
    /// paged to another picture since.
    private func thumbnail() -> MediaSources.Thumbnail? {
        guard let key = request.sourceKey else { return nil }
        return MediaSources.shared.thumbnail(for: key, origin: request.origin)
    }

    private func lift() {
        MediaSources.shared.lift(request.sourceKey, origin: request.origin)
    }

    // MARK: Closing

    /// Every way out — Escape, ✕, a click beside the picture, a throw, a
    /// squeeze — flies the picture home, and the stage goes when it lands.
    private func close(velocity: CGPoint = .zero) {
        guard !stage.isClosing else { return }
        playback.pauseForClose()
        stage.close(home: thumbnail(), velocity: velocity)
    }

    /// The picture has landed in its box: the box takes it back on the same
    /// pass that the stage goes, so there is no frame with both or neither.
    private func finish() {
        MediaSources.shared.lift(nil, origin: request.origin)
        dismiss()
    }

    // MARK: Paging

    private func paged(_ direction: Int) {
        if let jumpTarget {
            self.jumpTarget = nil
            show(jumpTarget)
        } else {
            step(direction)
        }
    }

    private func jump(to index: Int) {
        guard index != request.index, request.items.indices.contains(index), !stage.isClosing else { return }
        let direction = index > request.index ? 1 : -1
        // A neighbour is a page; anything further is the same page, with the
        // picture laid beside the stage first.
        if request.item(offsetBy: direction)?.id == request.items[index].id {
            stage.page(by: direction)
        } else {
            jumpTarget = index
            stage.jump(to: request.items[index], direction: direction)
        }
    }

    // MARK: Keys

    /// One handler rather than a modifier per key.
    ///
    /// **The arrows do what the media on screen does.** In a video they seek,
    /// as in every player; over a picture they turn the page, as in every
    /// viewer. Command-arrow always turns it.
    private func handle(key: KeyPress) -> KeyPress.Result {
        let isVideo = request.current?.isVideo ?? false
        switch key.key {
        case .escape:
            close()
        case .leftArrow where key.modifiers.contains(.command) || !isVideo:
            stage.page(by: -1)
        case .rightArrow where key.modifiers.contains(.command) || !isVideo:
            stage.page(by: 1)
        case .leftArrow:
            playback.skip(by: -5)
        case .rightArrow:
            playback.skip(by: 5)
        case .space:
            act()
        default:
            return .ignored
        }
        return .handled
    }

    /// Space: play or pause where something plays, fit or fill where not.
    private func act() {
        guard let item = request.current else { return }
        switch item.kind {
        case .video:
            playback.togglePlayback()
        case .animated where stage.frameCount > 1:
            stage.isFilmPlaying.toggle()
        case .animated, .image:
            stage.toggleZoom()
        }
    }
}

/// The scrim.
///
/// **Its own view so a fade is the only thing a gesture or a flight
/// invalidates.** Presence and dismissal move at frame rate; read from the
/// viewer's body they would re-evaluate the stage and both bars sixty times a
/// second during the moments that most need the frames.
///
/// It takes no clicks: the stage covers the window, and a click beside the
/// picture is the canvas's to answer (`onBackgroundClick`).
private struct MediaBackdrop: View {
    var stage: MediaStageController

    var body: some View {
        Rectangle()
            .fill(.black)
            .ignoresSafeArea()
            // A fixed scrim, not a material: what is behind it is the whole
            // window, and a sampled material cannot promise the picture on top
            // of it reads at any given moment (§4).
            .opacity(0.94 * stage.presence * (1 - stage.dismissProgress * 0.8))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Everything floating over the stage.
///
/// One view, so the fade is applied once — and so the viewer's own body never
/// reads presence or dismissal at all.
private struct MediaViewerChrome: View {
    var request: MediaViewerRequest
    var stage: MediaStageController
    var playback: VideoPlayback
    var actions: MediaActions
    var page: (Int) -> Void
    var jump: (Int) -> Void
    var close: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        // One container, so the pieces render as one pass of material while
        // they are up over a page turning or a picture being zoomed.
        GlassEffectContainer(spacing: 0) { content }
            .opacity(isShown ? 1 : 0)
            .animation(isShown ? motion.fade : motion.fadeQuick, value: isShown)
            .allowsHitTesting(isShown)
    }

    /// **Up once the picture has nearly landed, gone as soon as it takes off —
    /// never over a flight.** Clear glass re-samples whatever moves beneath it
    /// every frame, and six pieces of it over a picture growing out of its
    /// thumbnail halved the frame rate: 8–14 frames of 40 dropped opening and
    /// 5–8 closing, against 1–4 and 2 with the chrome waiting (measured from
    /// the compositor's own frame times, REDESIGN.md §9.4). The last tenth of a
    /// flight is a few points a frame, so the bars fading in over it cost
    /// nothing anyone sees; a throw takes them away the moment it starts.
    private var isShown: Bool {
        stage.presence >= 0.9 && !stage.isClosing && stage.dismissProgress < 0.02
    }

    private var content: some View {
        ZStack {
            MediaStatusOverlay(stage: stage, playback: playback)

            if let item = request.current {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        MediaGlassButton(systemImage: "xmark", label: "Close", action: close)
                        Spacer(minLength: Spacing.snug)
                        MediaActionCluster(
                            item: item,
                            authorName: request.authorName,
                            sentAt: request.sentAt,
                            actions: actions,
                            canCopyImage: !item.isVideo,
                            copyImage: copyImage
                        )
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: Spacing.base) {
                        if request.hasSiblings {
                            MediaGalleryStrip(request: request, select: jump)
                        }
                        bottomBar(for: item)
                    }
                }
                .padding(Spacing.margin)

                if request.hasSiblings {
                    steppers
                }
            }
        }
    }

    @ViewBuilder
    private func bottomBar(for item: MediaItem) -> some View {
        let bar = Group {
            if item.isVideo {
                MediaVideoControls(playback: playback)
                    .frame(maxWidth: 720)
            } else if stage.frameCount > 1 {
                MediaFilmControls(stage: stage)
                    .frame(maxWidth: 560)
            } else if stage.isZoomable {
                MediaZoomControls(stage: stage)
            }
        }
        bar
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.glass, style: .continuous))
            // A video's bar is not a picture's: the honest change between them
            // is a cross-fade, keyed on the kind.
            .transition(.materialize(from: .bottom))
    }

    /// The two chevrons. The position is said in their labels and in the
    /// strip, not in a "2 of 3" pill over somebody's photograph.
    private var steppers: some View {
        HStack {
            MediaGlassButton(systemImage: "chevron.left", label: "Previous (\(position))") { page(-1) }
            Spacer(minLength: 0)
            MediaGlassButton(systemImage: "chevron.right", label: "Next (\(position))") { page(1) }
        }
        .padding(.horizontal, Spacing.margin)
    }

    private var position: String {
        "\(request.index + 1) of \(request.items.count)"
    }

    private func copyImage() {
        guard let image = stage.currentImage() else { return }
        actions.copyImage(image)
    }
}

/// Loading, and the two ways this can fail. Its own view for the backdrop's
/// reason: both properties change rarely.
private struct MediaStatusOverlay: View {
    var stage: MediaStageController
    var playback: VideoPlayback

    var body: some View {
        Group {
            if let message = playback.failure ?? stage.failure {
                ContentUnavailableView(
                    "Couldn’t open this",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: 360)
            } else if stage.isLoading || playback.isBuffering {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .allowsHitTesting(false)
    }
}
