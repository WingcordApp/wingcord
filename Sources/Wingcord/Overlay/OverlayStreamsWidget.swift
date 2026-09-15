import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore

// MARK: - Screen shares, as tiles
//
// A separate widget from voice, and a *stack of tiles* rather than a roster —
// which is what the reference does and what the content asks for: a share is a
// picture, and a picture in a 20-point row is a row with a smudge in it.
//
// **The trap is that watching is a media session.** A second socket, a second
// MLS group and a decode per stream, so a widget that opened one per visible
// tile would start five of them the moment somebody glanced at the panel. The
// rule is the one `toggleWatchingStream` already enforces one window over: at
// most one open, and it is exactly the one the reader clicked. Every other tile
// is the REST thumbnail, which is a JPEG every few seconds and no session at
// all.

struct OverlayStreamsWidget: View {
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// Wide enough for a 16:9 frame that still reads as a screen.
    static let width: CGFloat = 268

    var body: some View {
        let sharers = self.sharers
        if !sharers.isEmpty {
            VStack(spacing: Spacing.base) {
                ForEach(sharers) { participant in
                    OverlayStreamTile(
                        participant: participant,
                        streamKey: model.streamKey(for: participant.id),
                        watch: { model.toggleWatchingStream(participant.id) },
                        toggleMute: { model.toggleLocalMute(participant.id) },
                        isLocallyMuted: model.isLocallyMuted(participant.id),
                        attachVideo: model.attachVideo
                    )
                }
            }
            .frame(width: Self.width)
            .animation(motion.standard, value: sharers.map(\.id))
        } else if controller.isEditingLayout {
            OverlayRestingSlot(
                symbol: "rectangle.inset.filled.on.rectangle",
                title: "Streams",
                detail: "Appears when somebody shares a screen."
            )
            .frame(width: Self.width, height: 72)
        }
    }

    /// Who in the call is sharing.
    ///
    /// **Our own share is not in the list**, for the reason `canWatch` already
    /// gives: watching our own would need a second voice websocket on the same
    /// `session_id`, and Discord closes one of the pair with 4006 — taking the
    /// published share down with it. Measured.
    private var sharers: [VoiceParticipant] {
        model.voicePresentation?.participants.filter(\.canWatch) ?? []
    }
}

// MARK: - One tile

private struct OverlayStreamTile: View {
    var participant: VoiceParticipant
    var streamKey: String?
    var watch: () -> Void
    var toggleMute: () -> Void
    var isLocallyMuted: Bool
    var attachVideo: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void

    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    /// How often an unwatched tile re-asks for its thumbnail.
    ///
    /// Discord's own preview rotates about this often; faster is a request for a
    /// frame that has not changed. The same number the voice flyout uses, and it
    /// is one number rather than two that can drift apart.
    private static let refresh = Duration.seconds(5)

    private var height: CGFloat { OverlayStreamsWidget.width * 9 / 16 }

    var body: some View {
        // **The chrome is an OVERLAY on the sized picture, not a sibling in a
        // stack that is sized afterwards.** A `ZStack` takes its size from its
        // largest child, and `picture` is an `aspectRatio(.fill)` image that
        // wants to be bigger than the tile — so the chrome's `VStack` was laid
        // out against *that* box and its bottom row, the name and the buttons,
        // fell outside the frame that clipped it. The capture showed a tile with
        // a play triangle and nothing else on it.
        picture
            .frame(width: OverlayStreamsWidget.width, height: height)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .overlay { chrome }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(
                        participant.isWatched ? Palette.accent.opacity(0.8) : .white.opacity(0.10),
                        lineWidth: participant.isWatched ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(participant.displayName) is sharing a screen")
    }

    // MARK: What fills the box

    /// **The live picture only for the one being watched.** Everything else is
    /// the thumbnail, and that is the whole economy of this widget.
    @ViewBuilder private var picture: some View {
        if participant.isWatched, participant.hasLiveVideo {
            VoiceVideoView(userID: participant.id, attach: attachVideo)
        } else {
            RemoteImage(
                url: streamKey.flatMap { model.streamPreviews[$0] },
                side: OverlayStreamsWidget.width,
                bucket: .artwork
            ) {
                ZStack {
                    Rectangle().fill(Palette.surfaceRaised)
                    Image(systemName: "rectangle.inset.filled.on.rectangle")
                        .font(.system(size: 20))
                        .foregroundStyle(Ink.quaternary)
                }
            }
            .aspectRatio(contentMode: .fill)
            // **Asked for only while the tile is NOT watched.** A watched tile
            // has the real picture; a thumbnail beside it is a request per five
            // seconds for a frame nobody looks at.
            //
            // A loop rather than a timer, so it dies with the tile: the task is
            // cancelled the moment the widget goes away, which is the moment the
            // overlay is dismissed.
            .task(id: streamKey) {
                guard let streamKey else { return }
                while !Task.isCancelled {
                    model.requestStreamPreview(key: streamKey)
                    try? await Task.sleep(for: Self.refresh)
                }
            }
        }
    }

    // MARK: What is drawn on it

    private var chrome: some View {
        ZStack {
            // **The play triangle covers the tile until it is watched**, which
            // is the reference's own signal that a picture is a still rather
            // than a stream. It is the tile's primary action and therefore the
            // whole tile, not a 44-point target in the middle of one.
            if !participant.isWatched {
                Button(action: watch) {
                    ZStack {
                        Color.black.opacity(isHovered ? 0.35 : 0.2)
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .chromeOverMedia(in: .circle)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Watch \(participant.displayName)'s screen")
            }

            VStack {
                HStack {
                    Spacer(minLength: 0)
                    LiveChip()
                }
                Spacer(minLength: 0)
                HStack(spacing: Spacing.tight) {
                    nameCapsule
                    Spacer(minLength: Spacing.tight)
                    if participant.isWatched { stopButton }
                    muteButton
                }
            }
            .padding(Spacing.base)
        }
    }

    /// The name, in its own capsule with the monitor glyph — the shape the
    /// reference uses and the one that reads over a moving picture. A name
    /// printed straight onto a screen share disappears whenever something light
    /// passes behind it.
    private var nameCapsule: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "display")
                .font(.system(size: 9, weight: .semibold))
            Text(participant.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.base)
        .frame(height: 22)
        .frame(maxWidth: OverlayStreamsWidget.width * 0.55, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .chromeOverMedia(in: .capsule)
    }

    private var stopButton: some View {
        tileButton(
            symbol: "stop.fill",
            help: "Stop watching",
            tint: Palette.destructive,
            action: watch
        )
    }

    /// **A local mute, and it is real rather than a picture of one.** The
    /// reference draws a speaker here; the engine has `setVolume(_:forUser:)`
    /// and nothing was using it, so this is the one control that button can
    /// honestly be — see `AppModel.toggleLocalMute`.
    private var muteButton: some View {
        tileButton(
            symbol: isLocallyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            help: isLocallyMuted ? "Unmute \(participant.displayName)" : "Mute \(participant.displayName)",
            tint: isLocallyMuted ? Palette.destructive : nil,
            action: toggleMute
        )
    }

    private func tileButton(
        symbol: String,
        help: String,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? .white)
                .frame(width: 26, height: 26)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help(help)
        .accessibilityLabel(help)
    }
}
