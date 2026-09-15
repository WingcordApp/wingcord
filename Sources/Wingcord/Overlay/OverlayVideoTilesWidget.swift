import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore

// MARK: - Cameras, as tiles
//
// A fourth widget, and the rarest of the four states — a call with cameras on.
//
// **The checkbox is not decoration, it is the decode.** The reference puts one
// on every tile and calls it "which cameras the widget shows"; here it also
// decides whether a sink is installed at all, which is the difference between a
// tile costing an `AVSampleBufferDisplayLayer` and costing an avatar. A widget
// that decoded six cameras over somebody's game while they looked at two would
// be spending a call's worth of hardware on pictures nobody asked for.
//
// Shown by default, because a video widget that starts empty reads as broken.
// The set is therefore an EXCLUSION — see `OverlayController.hiddenVideoUserIDs`.

struct OverlayVideoTilesWidget: View {
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    static let width: CGFloat = 132

    var body: some View {
        let cameras = self.cameras
        if !cameras.isEmpty {
            VStack(spacing: Spacing.base) {
                ForEach(cameras) { participant in
                    OverlayVideoTile(
                        participant: participant,
                        isShown: !controller.hiddenVideoUserIDs.contains(participant.id),
                        toggle: { controller.toggleVideoTile(participant.id) },
                        attachVideo: model.attachVideo
                    )
                }
            }
            .frame(width: Self.width)
            .animation(motion.standard, value: cameras.map(\.id))
        } else if controller.isEditingLayout {
            OverlayRestingSlot(
                symbol: "video",
                title: "Video Tiles",
                detail: "Appears when a camera is on."
            )
            .frame(width: Self.width * 2, height: 72)
        }
    }

    /// Everybody in the call with a camera on, the reader included.
    ///
    /// **The reader's own is in the list and a share is not.** A self-view is a
    /// capture preview and costs no network at all; a screen share is the
    /// streams widget's business and drawing it here would be the same picture
    /// in two widgets.
    private var cameras: [VoiceParticipant] {
        model.voicePresentation?.participants.filter(\.isCameraOn) ?? []
    }
}

// MARK: - One tile

private struct OverlayVideoTile: View {
    var participant: VoiceParticipant
    var isShown: Bool
    var toggle: () -> Void
    var attachVideo: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void

    @Environment(AppModel.self) private var model
    @State private var cameraSession: AVCaptureSession?

    private var height: CGFloat { OverlayVideoTilesWidget.width * 3 / 4 }

    var body: some View {
        ZStack {
            Rectangle().fill(Palette.surfaceRaised)
            picture
            chrome
        }
        .frame(width: OverlayVideoTilesWidget.width, height: height)
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(
                    participant.isSpeaking ? Palette.presenceOnline : .white.opacity(0.10),
                    lineWidth: participant.isSpeaking ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        // **The self-view is the capture session's own preview layer**, never an
        // inbound stream: asking Discord to send us back our own camera would be
        // a second encode of a picture already on this machine.
        .task(id: participant.isSelf && isShown) {
            guard participant.isSelf, isShown else {
                cameraSession = nil
                return
            }
            cameraSession = await model.cameraSession()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(participant.displayName)
    }

    @ViewBuilder private var picture: some View {
        if isShown, participant.hasLiveVideo || participant.isSelf {
            if let cameraSession {
                CameraPreviewView(session: cameraSession)
            } else if !participant.isSelf {
                VoiceVideoView(userID: participant.id, attach: attachVideo)
            }
        } else {
            AvatarView(
                url: participant.avatarURL,
                monogram: participant.monogram,
                side: 40
            )
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                checkbox
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: Spacing.hair) {
                if participant.isSilenced {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.destructive)
                }
                Text(participant.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 18)
            .chromeOverMedia(in: .capsule)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.tight)
    }

    /// The reference's own control, and the one that decides the decode.
    private var checkbox: some View {
        Button(action: toggle) {
            Image(systemName: isShown ? "checkmark.square.fill" : "square")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isShown ? Palette.accent : Color.white.opacity(0.8))
                // **A shadow rather than a plate.** The mark sits over a moving
                // picture, and a disc behind it would be a grey blot on somebody
                // else's face; a shadow separates it from anything underneath at
                // no cost to what shows through.
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isShown ? "Hide this camera" : "Show this camera")
        .accessibilityLabel(
            isShown ? "Hide \(participant.displayName)'s camera"
                : "Show \(participant.displayName)'s camera"
        )
    }
}
