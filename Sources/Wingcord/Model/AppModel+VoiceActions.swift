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

    /// Joins a guild voice channel.
    ///
    /// Gated on `CONNECT` — see `PermissionGate.canJoinVoice`. A direct call has
    /// no such bit and is not routed through here.
    func joinVoice(_ channelID: ChannelID) {
        guard permissionGate.canJoinVoice(channelID) else { return }
        let guildID = channelIndex[channelID]?.guildID
        voice.join(channelID: channelID, guildID: guildID)
    }

    /// Starts a call in a direct message and rings the other side.
    func startCall(in channelID: ChannelID) {
        voice.startDirectCall(channelID: channelID)
    }

    /// Joins a direct-message call that is already running.
    ///
    /// **The same act as answering, and deliberately not the same as starting.**
    /// Ringing somebody who is already sitting in the call is a phone going off
    /// in their ear for a call they are on — so this joins and rings nobody,
    /// exactly as `answerCall` does.
    func joinCall(in channelID: ChannelID) {
        voice.join(channelID: channelID, guildID: nil)
    }

    func leaveVoice() {
        // The local mutes belong to the call, not to the account — see
        // `locallyMutedUserIDs`.
        locallyMutedUserIDs = []
        voice.leave()
    }

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
        // **A camera and a share are two media sessions now, so they coexist.**
        // This used to stop the share, because both went down the call's one
        // video track and the second to start would have overwritten the first.
        // A Go Live stream has its own session, its own SSRCs and its own MLS
        // group — which is what Discord's own client does, and why it lets you
        // be on camera while sharing.
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
        var quality = ScreenShareCapture.Quality.standard
        let settings = AppSettings.shared
        quality.width = settings.videoWidth
        quality.height = settings.videoHeight
        quality.framerate = settings.videoFramerate
        quality.capturesAudio = settings.sharesSystemAudio
        voice.startScreenShare(target: target, quality: quality)
    }

    /// Opens somebody's screen share, or closes the one that is open.
    ///
    /// **One at a time.** Watching costs a socket, an MLS group and a decode
    /// per stream; two at once is twice that for a picture nobody is looking at
    /// — and the tile that would draw the second is behind the first.
    func toggleWatchingStream(_ userID: UserID) {
        if watchedStreamUserID == userID {
            voice.stopWatchingStream()
        } else {
            if watchedStreamUserID != nil { voice.stopWatchingStream() }
            voice.watchStream(owner: userID)
        }
    }

    /// Silences one person for the rest of this call, or lets them back.
    ///
    /// **The engine already had the knob and nothing was turning it.**
    /// `VoiceController.setVolume(_:forUser:)` reaches the mixer's per-stream
    /// gain, which is the one honest thing a speaker button on a stream tile can
    /// mean: a client cannot stop Discord sending the audio, only stop playing
    /// it, and saying so with a local gain is better than a control that
    /// pretends to reach the other end.
    func toggleLocalMute(_ userID: UserID) {
        guard userID != currentUserID else { return }
        let muted = locallyMutedUserIDs.contains(userID)
        if muted {
            locallyMutedUserIDs.remove(userID)
        } else {
            locallyMutedUserIDs.insert(userID)
        }
        voice.setVolume(muted ? 1 : 0, forUser: userID)
    }

    func isLocallyMuted(_ userID: UserID) -> Bool { locallyMutedUserIDs.contains(userID) }

    /// The address of somebody's share, for the thumbnail route.
    ///
    /// Built rather than stored, because it is a pure function of three ids —
    /// see `GoLiveKey`. Nil for anybody who is not sharing, which is what keeps
    /// a tile from asking Discord for a picture of nothing.
    func streamKey(for userID: UserID) -> String? {
        guard let channelID = connectedVoiceChannelID,
              voiceStates[userID]?.isStreaming == true
        else { return nil }
        return GoLiveKey.make(
            guildID: channelIndex[channelID]?.guildID,
            channelID: channelID,
            userID: userID
        )
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
