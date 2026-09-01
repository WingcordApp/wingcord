import AVFoundation
import CoreMedia
import Foundation
import WingcordCore
import WingcordVoice

// MARK: - What a call surface can ask for
//
// Forwarding, exactly as the guild pages and the profile card forward: a view
// calls the store, and the store hands it to the controller that owns the
// connection. The store never talks to the network and the network never touches
// the store — everything crosses in one direction, at one place.

extension AppModel {

    private var voice: VoiceController { sessionController.voice }

    // MARK: Joining

    func joinVoice(_ channelID: ChannelID) {
        let guildID = channelIndex[channelID]?.guildID
        voice.join(channelID: channelID, guildID: guildID)
    }

    /// Starts a call in a direct message and rings the other side.
    func startCall(in channelID: ChannelID) {
        voice.startDirectCall(channelID: channelID)
    }

    func leaveVoice() { voice.leave() }

    func declineCall(in channelID: ChannelID) { voice.decline(channelID: channelID) }

    /// Answers a ringing call.
    func answerCall(in channelID: ChannelID) {
        incomingCallChannelID = nil
        voice.join(channelID: channelID, guildID: nil)
    }

    // MARK: Switches

    func toggleVoiceMute() { voice.setMuted(!isSelfMuted) }

    func toggleVoiceDeafen() { voice.setDeafened(!isSelfDeafened) }

    func toggleCamera() {
        // A camera and a screen share are one video stream on this protocol, so
        // turning one on turns the other off rather than failing silently.
        if isScreenSharing { voice.stopScreenShare() }
        voice.setCameraOn(!isCameraOn)
    }

    /// Opens the picker, or stops a share already running.
    func toggleScreenShare() {
        if isScreenSharing {
            voice.stopScreenShare()
        } else {
            isScreenSharePickerOpen = true
        }
    }

    func startScreenShare(target: ShareableTarget) {
        isScreenSharePickerOpen = false
        if isCameraOn { voice.setCameraOn(false) }
        var quality = ScreenShareCapture.Quality.standard
        let settings = AppSettings.shared
        quality.width = settings.videoWidth
        quality.height = settings.videoHeight
        quality.framerate = settings.videoFramerate
        quality.capturesAudio = settings.sharesSystemAudio
        voice.startScreenShare(target: target, quality: quality)
    }

    func setPushToTalkHeld(_ held: Bool) { voice.setPushToTalkHeld(held) }

    func spotlight(_ userID: UserID?) {
        guard spotlightUserID != userID else { return }
        spotlightUserID = userID
    }

    /// Re-applies the settings window's choices to a call already running.
    func voicePreferencesChanged() { voice.applyPreferences() }

    // MARK: Media plumbing

    /// Where somebody's decoded video goes.
    nonisolated func attachVideo(
        _ userID: UserID,
        to sink: (@Sendable (CMSampleBuffer) -> Void)?
    ) {
        MainActor.assumeIsolated { voice.setVideoSink(sink, for: userID) }
    }

    /// The camera's own session, for the self-view.
    func cameraSession() async -> AVCaptureSession? {
        await voice.cameraSession()
    }

    // MARK: The soundboard

    /// Fetches one server's soundboard, when its section is looked at.
    func loadSoundboard(inGuild guildID: GuildID) { voice.loadSoundboard(inGuild: guildID) }

    func pressSound(_ id: String) {
        guard let sound = soundboardSound(id: id) else { return }
        voice.press(sound)
    }
}
