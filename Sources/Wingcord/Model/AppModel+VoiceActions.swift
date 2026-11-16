import AVFoundation
import CoreMedia
import Foundation
import WingcordCore
import WingcordNet
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

    /// Starts a call in a direct message and rings the other side — or, when
    /// somebody is already in it, joins it and rings nobody.
    ///
    /// **Decided here, not by each control** (#14, "it has to recall every time
    /// you want to join a vc that is already active"). The header's button
    /// asked first, but the shortcut, the menu bar, the conversation's menu
    /// and a profile's Call came straight here and rang a phone in the ear of
    /// everybody already on the call.
    func startCall(in channelID: ChannelID) {
        if isDirectCallRunning(in: channelID) {
            joinCall(in: channelID)
            return
        }
        voice.startDirectCall(channelID: channelID)
    }

    /// Discord's Start Video Call: the same call, with the camera on — joined
    /// without ringing when it is already running.
    func startVideoCall(in channelID: ChannelID) {
        if isDirectCallRunning(in: channelID) {
            voice.joinDirectCall(channelID: channelID, withCamera: true)
            return
        }
        voice.startDirectCall(channelID: channelID, withCamera: true)
    }

    /// Whether somebody other than the reader is sitting in a conversation's
    /// call. Read from the voice states rather than from `directCalls`, which
    /// survives the last person leaving — the same rule the header draws.
    func isDirectCallRunning(in channelID: ChannelID) -> Bool {
        connectedVoiceChannelID != channelID
            && voiceStates.values.contains { $0.channelID == channelID && $0.userID != currentUserID }
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
        showsNonVideoParticipants = true
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
        // Discord's "Always preview video" (module 442353): turning the camera
        // on goes through its preview.
        if !isCameraOn, syncedPreferences.alwaysPreviewsVideo {
            previewCamera()
            return
        }
        // **A camera and a share are two media sessions now, so they coexist.**
        // This used to stop the share, because both went down the call's one
        // video track and the second to start would have overwritten the first.
        // A Go Live stream has its own session, its own SSRCs and its own MLS
        // group — which is what Discord's own client does, and why it lets you
        // be on camera while sharing.
        voice.setCameraOn(!isCameraOn)
    }

    /// Discord's Preview Camera.
    func previewCamera() {
        userMenu = nil
        isCameraPreviewOpen = true
    }

    /// The preview's Turn On Camera — past the preview, whatever the setting.
    func turnOnCameraFromPreview() {
        voice.setCameraOn(true)
    }

    /// "Always preview video", written to the account as Discord's is.
    func setAlwaysPreviewsVideo(_ previews: Bool) {
        let previous = syncedPreferences
        guard previous.alwaysPreviewsVideo != previews else { return }
        syncedPreferences.alwaysPreviewsVideo = previews
        sessionController.writeSyncedPreference(.alwaysPreviewsVideo(previews), restoring: previous)
    }

    /// Opens the Go Live sheet, or stops a share already running.
    func toggleScreenShare() {
        if isScreenSharing {
            voice.stopScreenShare()
        } else {
            voice.openGoLive()
        }
    }

    func closeGoLive() { voice.closeGoLive() }

    func pickScreenSource() { voice.pickScreenSource() }

    func goLive() { voice.goLive() }

    func stopScreenShare() { voice.stopScreenShare() }

    /// Discord's Stream Quality and Share Audio, before going live or during.
    func updateGoLive(_ settings: GoLiveSettings) { voice.updateGoLive(settings) }

    /// Where the Go Live sheet's preview draws.
    nonisolated func attachGoLivePreview(_ sink: (@Sendable (CMSampleBuffer) -> Void)?) {
        MainActor.assumeIsolated { voice.setGoLivePreviewSink(sink) }
    }

    /// Who may stream at what in the call the reader is in: the account's
    /// subscription, or the server's boosts.
    var goLiveGate: GoLiveGate {
        GoLiveGate(
            premiumTier: entitlements.premiumTier,
            guildBoostTier: connectedVoiceChannelID
                .flatMap { channelIndex[$0]?.guildID }
                .flatMap { guilds[$0]?.premiumTier } ?? 0,
            isUnlocked: AppSettings.shared.liftsStreamQuality
        )
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

    // MARK: One person's sound
    //
    // Discord's person menu in a call: User Volume, Mute, Mute Soundboard and
    // Disable Video — and a stream's own volume. The first three are the
    // account's, synced across devices (`audioContext`); a disabled video
    // stays on this Mac, as Discord keeps it.

    /// Discord's User Volume — or, for their stream, Stream Volume — as a gain.
    func setVolume(_ volume: Double, of userID: UserID, in context: AudioContextSettings.Context) {
        guard userID != currentUserID else { return }
        audioContext.setVolume(max(0, min(2, volume)), of: userID, in: context, at: .now)
        audioContextChanged(userID, in: context)
    }

    /// Discord's Mute, for one person and for this reader alone: not played,
    /// and the server told not to send it — their volume untouched, so letting
    /// them back brings them back where they were.
    func toggleLocalMute(_ userID: UserID, in context: AudioContextSettings.Context = .user) {
        guard userID != currentUserID else { return }
        audioContext.setMuted(!audioContext.isMuted(userID, in: context), of: userID, in: context, at: .now)
        audioContextChanged(userID, in: context)
    }

    func isLocallyMuted(_ userID: UserID) -> Bool { audioContext.isMuted(userID) }

    /// Discord's Mute Soundboard: their sounds are not played here.
    func toggleSoundboardMute(_ userID: UserID) {
        guard userID != currentUserID else { return }
        let muted = !(audioContext.users[userID]?.isSoundboardMuted ?? false)
        audioContext.setSoundboardMuted(muted, of: userID, at: .now)
        audioContextChanged(userID, in: .user)
    }

    private func audioContextChanged(_ userID: UserID, in context: AudioContextSettings.Context) {
        voice.applyAudioContext()
        sessionController.scheduleAudioContextWrite(
            AudioContextProto.Change(
                context: context, userID: userID, entry: audioContext[context][userID]
            )
        )
    }

    /// Discord's Disable Video, for one person, kept on this Mac.
    func toggleVideoDisabled(_ userID: UserID) {
        guard userID != currentUserID else { return }
        let settings = AppSettings.shared
        let disabled = !settings.disabledVideoUserIDs.contains(userID.rawValue)
        if disabled {
            settings.disabledVideoUserIDs.insert(userID.rawValue)
        } else {
            settings.disabledVideoUserIDs.remove(userID.rawValue)
        }
        voice.setVideoDisabled(disabled, userID: userID)
    }

    func isVideoDisabled(_ userID: UserID) -> Bool {
        AppSettings.shared.disabledVideoUserIDs.contains(userID.rawValue)
    }

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

    func setPriorityHeld(_ held: Bool) { voice.setPriorityHeld(held) }

    func spotlight(_ userID: UserID?) {
        guard spotlightUserID != userID else { return }
        spotlightUserID = userID
    }

    /// Whose camera the call asks for whole — Discord's selected participant:
    /// the spotlight, unless it is showing their share, which arrives on a
    /// session of its own.
    var focusedCameraUserID: UserID? {
        guard let spotlightUserID, spotlightUserID != watchedStreamUserID else { return nil }
        return spotlightUserID
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

    /// How big somebody's picture is drawn, for a one-to-one call's want.
    nonisolated func reportVideoPixels(_ userID: UserID, _ pixels: Int) {
        MainActor.assumeIsolated { voice.setDrawnPixels(pixels, for: userID) }
    }

    /// The camera's own session, for the self-view.
    func cameraSession() async -> CaptureSessionHandle? {
        await voice.cameraSession()
    }

    // MARK: The soundboard

    /// Fetches one server's soundboard, when its section is looked at.

    func pressSound(_ id: String) {
        guard let sound = soundboardSound(id: id) else { return }
        voice.press(sound)
    }

    /// Discord's Preview — the sound here only.
    func previewSound(_ id: String) {
        guard let sound = soundboardSound(id: id) else { return }
        voice.preview(sound)
    }

    func soundboardDidOpen() {
        voice.soundboardDidOpen()
    }

    func setFavoriteSound(_ id: String, favorite: Bool) {
        voice.setFavoriteSound(id, favorite: favorite)
    }

    /// Soundboard Volume, as the slider moves — heard at once, written to the
    /// account when the slider is let go (`commitSoundboardVolume`).
    func setSoundboardVolume(_ volume: Float) {
        syncedPreferences.soundboardVolume = min(100, max(0, volume))
    }

    func commitSoundboardVolume(from previous: SyncedPreferences) {
        guard previous.soundboardVolume != syncedPreferences.soundboardVolume else { return }
        sessionController.writeSyncedPreference(
            .soundboardVolume(syncedPreferences.soundboardVolume), restoring: previous
        )
    }
}
