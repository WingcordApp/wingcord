import SwiftUI

/// The bar under a video.
///
/// **The scrubber is a system `Slider`.** It is the control macOS already draws
/// with the platform's own glass, its own pointer response and its own
/// accessibility, and a hand-rolled track would have to reimplement all three to
/// arrive somewhere worse. `INVARIANTS.md` §1 says the same thing about toolbar
/// controls for the same reason.
///
/// The two labels read whole seconds and the track reads the fine value, which
/// is why `VideoPlayback` publishes both: a timestamp invalidated ten times a
/// second to draw the same four characters is nine wasted evaluations out of
/// ten.
struct MediaVideoControls: View {
    @Bindable var playback: VideoPlayback

    @State private var scrubValue: Double = 0

    var body: some View {
        HStack(spacing: Spacing.snug) {
            MediaBarControl(
                systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                label: playback.isPlaying ? "Pause" : "Play",
                action: playback.togglePlayback
            )

            Text(mediaTimeLabel(playback.elapsedSeconds))
                .font(Typeface.metadata.monospacedDigit())
                .foregroundStyle(InkColor.secondary)

            Slider(value: $scrubValue, in: 0...max(playback.duration, 0.01)) { isEditing in
                if isEditing {
                    playback.beginScrub()
                } else {
                    playback.endScrub(at: scrubValue)
                }
            }
            .disabled(playback.duration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue(mediaTimeLabel(playback.elapsedSeconds))

            Text("−" + mediaTimeLabel(playback.remainingSeconds))
                .font(Typeface.metadata.monospacedDigit())
                .foregroundStyle(InkColor.secondary)

            MediaRateMenu(rate: $playback.rate, choices: VideoPlayback.rates)

            MediaVolumeControls(playback: playback)

            MediaBarControl(
                systemImage: "repeat",
                label: playback.isLooping ? "Stop looping" : "Loop",
                isActive: playback.isLooping,
                action: { playback.isLooping.toggle() }
            )
        }
        // The clock drives the thumb whenever the reader is not holding it;
        // `isScrubbing` is what keeps the two from fighting for the same value
        // ten times a second.
        .onChange(of: playback.currentTime) { _, time in
            guard !playback.isScrubbing else { return }
            scrubValue = time
        }
        .onChange(of: scrubValue) { _, value in
            guard playback.isScrubbing else { return }
            playback.scrub(to: value)
        }
    }
}

/// Mute, and how loud.
///
/// Inline rather than behind a hover-revealed popover: the slider is seventy
/// points, the bar has the room, and a control that has to be discovered by
/// hovering the right disc is one most people never find.
private struct MediaVolumeControls: View {
    @Bindable var playback: VideoPlayback

    var body: some View {
        HStack(spacing: Spacing.tight) {
            MediaBarControl(
                systemImage: glyph,
                label: playback.isMuted ? "Unmute" : "Mute",
                action: playback.toggleMute
            )
            Slider(value: $playback.volume, in: 0...1)
                .frame(width: 74)
                .disabled(playback.isMuted)
                .accessibilityLabel("Volume")
        }
    }

    /// Three states, not two: silent, quiet and loud. A single filled speaker
    /// for every level above zero throws away the only feedback the glyph can
    /// give about where the slider is.
    private var glyph: String {
        if playback.isMuted || playback.volume <= 0.001 { return "speaker.slash.fill" }
        return playback.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}

/// The bar under something that moves but has no soundtrack.
///
/// **The scrubber steps FRAMES, not seconds.** A filmstrip is a fixed list of
/// pictures with a duration attached, so the honest unit is the frame — and a
/// frame counter is what makes a GIF something a reader can actually examine
/// rather than only watch.
struct MediaFilmControls: View {
    @Bindable var stage: MediaStageController

    @State private var scrubValue: Double = 0
    /// Whether playback was running when the scrub began, so letting go puts it
    /// back the way the reader found it.
    @State private var resumesAfterScrub = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            MediaBarControl(
                systemImage: stage.isFilmPlaying ? "pause.fill" : "play.fill",
                label: stage.isFilmPlaying ? "Pause" : "Play",
                action: { stage.isFilmPlaying.toggle() }
            )

            Slider(value: $scrubValue, in: 0...Double(max(stage.frameCount - 1, 1)), step: 1) { isEditing in
                if isEditing {
                    resumesAfterScrub = stage.isFilmPlaying
                    stage.isFilmPlaying = false
                } else if resumesAfterScrub {
                    stage.isFilmPlaying = true
                }
            }
            .accessibilityLabel("Frame")
            .accessibilityValue("\(stage.frameIndex + 1) of \(stage.frameCount)")

            Text("\(stage.frameIndex + 1)/\(stage.frameCount)")
                .font(Typeface.metadata.monospacedDigit())
                .foregroundStyle(InkColor.secondary)

            MediaRateMenu(rate: $stage.filmRate, choices: MediaFilmControls.rates)
        }
        .onChange(of: stage.frameIndex) { _, index in
            guard !stage.isFilmPlaying || scrubValue != Double(index) else { return }
            scrubValue = Double(index)
        }
        .onChange(of: scrubValue) { _, value in
            guard !stage.isFilmPlaying else { return }
            stage.seekFilm(toFrame: Int(value))
        }
    }

    /// Slower than the video set, and it goes further down: a reaction GIF at a
    /// quarter speed is the whole point of being able to change it.
    static let rates: [Double] = [1, 0.25, 0.5, 2]
}

/// How fast, as a menu.
///
/// One over its own glyph rather than a row of five buttons: the answer is 1
/// nearly every time, and four permanent controls for the exceptions is four
/// controls of chrome over somebody's picture.
private struct MediaRateMenu: View {
    @Binding var rate: Double
    var choices: [Double]

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(choices, id: \.self) { choice in
                // A tick beside the current one rather than a disabled row: the
                // speed already applied is still a legitimate thing to choose,
                // and a greyed-out entry reads as unavailable.
                Button {
                    rate = choice
                } label: {
                    if choice == rate {
                        Label(Self.label(choice), systemImage: "checkmark")
                    } else {
                        Text(Self.label(choice))
                    }
                }
            }
        } label: {
            Text(Self.label(rate))
                .font(Typeface.metadata.monospacedDigit())
                .foregroundStyle(rate == 1 ? AnyShapeStyle(InkColor.secondary) : AnyShapeStyle(Palette.accent))
                .frame(minWidth: Metrics.control, minHeight: Metrics.control)
                .background { Capsule().fill(.white.opacity(isHovering ? 0.16 : 0.08)) }
                .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .help("Playback speed")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Self.label(rate))
    }

    /// `1×`, `0.5×`. Written rather than formatted so the trailing zero of a
    /// half is never shown and the row never changes width as the choice
    /// changes.
    private static func label(_ value: Double) -> String {
        let whole = value.rounded()
        let text = abs(value - whole) < 0.001
            ? String(Int(whole))
            : value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text)×"
    }
}

/// The bar under a still picture.
///
/// Present for anything that zooms and absent for anything that does not, so the
/// bar under a video is a video's bar and nothing else. The percentage is a
/// button, because the only thing anybody wants to do with a zoom readout is put
/// it back.
struct MediaZoomControls: View {
    var stage: MediaStageController

    @State private var zoomValue: Double = 1

    var body: some View {
        HStack(spacing: Spacing.snug) {
            MediaBarControl(
                systemImage: "minus.magnifyingglass",
                label: "Zoom out",
                isEnabled: stage.zoomScale > 1.001,
                action: stage.zoomOut
            )

            Slider(value: $zoomValue, in: 1...Double(max(stage.maximumZoom, 1.01)))
                .frame(width: 160)
                .accessibilityLabel("Zoom")
                .accessibilityValue(label)

            MediaBarControl(
                systemImage: "plus.magnifyingglass",
                label: "Zoom in",
                isEnabled: stage.zoomScale < stage.maximumZoom - 0.001,
                action: stage.zoomIn
            )

            Button(action: stage.resetZoom) {
                Text(label)
                    .font(Typeface.metadata.monospacedDigit())
                    .foregroundStyle(InkColor.secondary)
                    .frame(minWidth: 44, minHeight: Metrics.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(stage.zoomScale <= 1.001)
            .help("Fit to window")
            .accessibilityLabel("Fit to window")
        }
        .onChange(of: stage.zoomScale) { _, scale in
            let value = Double(scale)
            guard abs(zoomValue - value) > 0.001 else { return }
            zoomValue = value
        }
        .onChange(of: zoomValue) { _, value in
            guard abs(Double(stage.zoomScale) - value) > 0.001 else { return }
            stage.setZoom(CGFloat(value))
        }
    }

    private var label: String {
        stage.zoomScale <= 1.001
            ? "Fit"
            : "\(Double(stage.zoomScale).formatted(.number.precision(.fractionLength(0...1))))×"
    }
}
