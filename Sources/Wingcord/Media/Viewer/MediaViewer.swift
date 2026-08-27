import SwiftUI

/// The lightbox: one picture, one clip or one animation, at the size the window
/// can give it.
///
/// **One surface for all three kinds, with three sets of controls.** What a
/// reader does with a photograph and what they do with a video have almost
/// nothing in common — one zooms, the other scrubs — so the bar under the stage
/// is built from the kind and only the top bar is shared. A single bar carrying
/// every control for every kind would be four fifths disabled at all times.
///
/// **The stage is inset above the chrome for video and full-bleed for
/// everything else**, and that asymmetry is `INVARIANTS.md` §4's last rule
/// rather than an oversight: glass over playing video re-samples its blur every
/// frame and leaves the glyphs on top of it illegible, so the bars sit over the
/// scrim instead. A still picture — even one that animates — is exactly what
/// clear glass is for, and letting it pass underneath is the whole reason this
/// app uses the material at all.
struct MediaViewer: View {
    var request: MediaViewerRequest
    var step: (Int) -> Void
    var close: () -> Void

    /// How much of the stage the chrome reserves at each end, for video.
    private static let chromeBand: CGFloat = 76

    @State private var stage = MediaStageController()
    @State private var playback = VideoPlayback()
    @State private var actions = MediaActions()
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            MediaBackdrop(stage: stage, close: close)

            if let item = request.current {
                MediaStage(
                    item: item,
                    controller: stage,
                    player: item.isVideo ? playback.player : nil,
                    onDismiss: close,
                    onContentClick: playback.togglePlayback
                )
                .padding(.vertical, item.isVideo ? Self.chromeBand : 0)
                // **A picture runs to the window's edges; a video stops at the
                // safe area.** Letting a still pass under the titlebar is the
                // same thing the transcript does and is the whole reason the
                // chrome is glass. A video cannot: §4's last rule sends
                // anything over playing video to a scrim, and the window's own
                // titlebar is not one this app controls.
                //
                // A parameter rather than an `if`, so the stage keeps one
                // identity and stepping from a photograph to a clip does not
                // rebuild the player underneath it.
                .ignoresSafeArea(edges: item.isVideo ? [] : .all)
                .accessibilityLabel(Text(item.altText ?? item.filename))

                MediaViewerChrome(
                    request: request,
                    stage: stage,
                    playback: playback,
                    actions: actions,
                    step: step,
                    close: close
                )
            }
        }
        // **The chrome respects the safe area and everything under it ignores
        // it.** `NSTitlebarView` is a sibling *above* the hosting view — §1 —
        // so a bar drawn into the titlebar's strip is a bar with the traffic
        // lights and the app's own toolbar items printed on top of it. Measured
        // on a live window: the close button landed underneath the red one.
        // The viewer takes the keyboard for as long as it is up: Escape closes,
        // the arrows do what the kind on screen says they do, and space is the
        // universal "act on this".
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onExitCommand(perform: close)
        .onKeyPress(action: handle(key:))
        // Loading is keyed on the item, so stepping between attachments swaps
        // what the player holds instead of building a second one.
        .task(id: request.current?.id) {
            let item = request.current
            playback.load(
                url: item?.isVideo == true ? item?.sourceURL : nil,
                identity: item?.id.rawValue,
                autoplay: true
            )
        }
        // Only the player. A save in flight is deliberately left to finish —
        // see `MediaActions.save`.
        .onDisappear(perform: playback.tearDown)
    }

    // MARK: Keys

    /// One handler rather than a modifier per key.
    ///
    /// **The arrows do what the media on screen does.** In a video they seek,
    /// which is what they do in every player; over a picture they step to the
    /// next attachment, which is what they do in every viewer. Command-arrow
    /// always steps, so the one gesture that means "next" is available whatever
    /// is showing.
    private func handle(key: KeyPress) -> KeyPress.Result {
        let isVideo = request.current?.isVideo ?? false
        switch key.key {
        case .escape:
            close()
        case .leftArrow where key.modifiers.contains(.command) || !isVideo:
            step(-1)
        case .rightArrow where key.modifiers.contains(.command) || !isVideo:
            step(1)
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

    /// What the space bar means here: play or pause where there is something
    /// playing, and fit or fill where there is not.
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

/// The scrim, and the click that lands on nothing.
///
/// **Its own view so the fade is the only thing a dismiss gesture
/// invalidates.** `dismissProgress` moves at event rate; read from the viewer's
/// own body it would re-evaluate the stage, both bars and everything they are
/// built from, sixty times a second during the one gesture that most needs the
/// frames.
private struct MediaBackdrop: View {
    var stage: MediaStageController
    var close: () -> Void

    var body: some View {
        Rectangle()
            .fill(.black)
            .ignoresSafeArea()
            // A fixed scrim, not a material. What is behind it is the whole
            // window — a transcript, a roster, artwork — and a sampled material
            // cannot promise the picture on top of it reads at any given
            // moment. §4 sends anything over content nobody chose to a scrim
            // for exactly this reason.
            .opacity(0.94 * (1 - stage.dismissProgress * 0.8))
            .contentShape(.rect)
            .onTapGesture(perform: close)
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
    }
}

/// Everything floating over the stage.
///
/// One view, so the dismiss fade is applied once — and so the viewer's own body
/// never reads `dismissProgress` at all.
private struct MediaViewerChrome: View {
    var request: MediaViewerRequest
    var stage: MediaStageController
    var playback: VideoPlayback
    var actions: MediaActions
    var step: (Int) -> Void
    var close: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            MediaStatusOverlay(stage: stage, playback: playback)

            if let item = request.current {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        MediaGlassButton(
                            systemImage: "xmark",
                            label: "Close",
                            action: close
                        )
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
                    bottomBar(for: item)
                }
                .padding(Spacing.margin)

                if request.hasSiblings {
                    steppers
                }
            }
        }
        // The chrome goes with the picture: a bar left at full strength over a
        // surface being thrown away reads as two things happening rather than
        // one.
        .opacity(1 - stage.dismissProgress)
        .allowsHitTesting(stage.dismissProgress < 0.02)
        .animation(motion.fade, value: request.index)
    }

    @ViewBuilder
    private func bottomBar(for item: MediaItem) -> some View {
        Group {
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
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Radius.glass, style: .continuous)
        )
        // The bar for a video is not the bar for a picture, and a cross-fade
        // between them is the honest way to say so. Keyed on the kind rather
        // than on the item, so stepping between two photographs leaves the bar
        // alone.
        .transition(.materialize(from: .bottom))
    }

    /// The two chevrons, and the only place the position is said.
    ///
    /// **In the label rather than in a counter on screen.** A "2 of 3" pill is a
    /// second piece of permanent chrome over the picture saying what the
    /// chevrons' presence already says; put in the help text and the
    /// accessibility label it costs nothing and is still available to anyone who
    /// asks for it.
    private var steppers: some View {
        HStack {
            MediaGlassButton(
                systemImage: "chevron.left",
                label: "Previous (\(position))",
                action: { step(-1) }
            )
            Spacer(minLength: 0)
            MediaGlassButton(
                systemImage: "chevron.right",
                label: "Next (\(position))",
                action: { step(1) }
            )
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

/// Loading, and the two ways this can fail.
///
/// **Its own view for the same reason the backdrop is one**: both of the
/// properties it reads change rarely, and reading them from the viewer's body
/// would tie the whole surface to a spinner.
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
