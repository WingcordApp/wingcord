import AppKit
import AVFoundation
import CoreMedia
import Foundation
import OSLog
import WingcordCore
import WingcordNet
import WingcordVoice

// MARK: - Joining, and everything that follows from it
//
// The one place the app's store and the media engine meet. It owns the engine,
// it is the only thing that constructs one, and it applies what comes back.
//
// **Joining is a two-halves handshake and neither half is enough.** Op 4 over
// the main socket answers with our own `VOICE_STATE_UPDATE` — carrying the
// session id — and a `VOICE_SERVER_UPDATE` — carrying the endpoint and the
// token. The two arrive in either order, on separate frames, and a client that
// waits for one and assumes the other silently fails to connect once every few
// joins. `pending` is the latch that makes the order not matter.
@MainActor
final class VoiceController {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "VoiceSession")

    unowned let model: AppModel
    private let rest: DiscordREST
    private weak var socket: GatewaySocket?

    /// The call's media session. The share and the watch below are the same
    /// type, each its own session on the wire — see `MediaSession`.
    private var engine: MediaSession?
    /// Whether a call's audio is up — what the system's mute gesture is held for.
    var hasCallAudio: Bool { engine != nil }
    /// The call's session, to lend a voice message its microphone.
    var currentSession: MediaSession? { engine }
    private var engineTask: Task<Void, Never>?
    /// The two halves of the credential, as they arrive.
    private var pendingSession: String?
    private var pendingServer: VoiceServer?
    /// Where we asked to be. Held so a `VOICE_STATE_UPDATE` for somebody else
    /// in the same channel cannot be mistaken for our own answer.
    private var joiningChannelID: ChannelID?
    private var joiningGuildID: GuildID?

    // MARK: The Go Live stream
    //
    // **A second media session, with a second two-half credential.** A stream
    // is not the call: `STREAM_CREATE` carries its key and its `rtc_server_id`,
    // `STREAM_SERVER_UPDATE` carries its endpoint and token, and — exactly as
    // `VOICE_STATE_UPDATE` and `VOICE_SERVER_UPDATE` do — the two arrive in no
    // guaranteed order. These are that latch.

    private var stream: MediaSession?
    private var streamTask: Task<Void, Never>?
    /// The capture behind the Go Live sheet, picked and previewing, sending
    /// nothing. See `startDraft`.
    private var draftShare: ScreenShareCapture?
    /// The sheet's preview surface, kept because it attaches before anything
    /// has been picked.
    private var goLivePreviewSink: (@Sendable (CMSampleBuffer) -> Void)?
    /// The capture that went live, and what it runs at — held from Go Live,
    /// through opcode 18 and both halves of the credential, until the share
    /// ends. The stream's session takes it over once it exists.
    private var liveShare: (capture: ScreenShareCapture, quality: ScreenShareCapture.Quality)?
    private var pendingStreamKey: String?
    private var pendingStreamSession: GoLiveSession?
    private var pendingStreamServer: GoLiveServer?
    /// The self tile's sink, kept because the tile attaches before the stream
    /// session exists — a share started after the tile is on screen would
    /// otherwise have nowhere to draw.
    private var streamPreviewSink: (@Sendable (CMSampleBuffer) -> Void)?

    // MARK: Watching somebody else's stream
    //
    // The receive mirror of the block above, with the same two-half latch — a
    // viewer is told about the stream it asked for in exactly the frames its
    // owner was.

    private var watch: MediaSession?
    private var watchTask: Task<Void, Never>?
    /// Whose stream opcode 20 has been sent for, and under which key. Held from
    /// the moment we ask until both halves have arrived.
    private var pendingWatch: (owner: UserID, key: String)?
    private var pendingWatchSession: GoLiveSession?
    private var pendingWatchServer: GoLiveServer?
    /// The watched tile's sink, kept for the same reason the self tile's is.
    private var watchSink: (@Sendable (CMSampleBuffer) -> Void)?
    /// Credentials already received, by whose stream they are for.
    ///
    /// **Discord answers opcode 20 once.** A second request for a stream this
    /// account is already registered as a viewer of is accepted and answered
    /// with nothing — measured, as two `stream watch ->` lines against one
    /// `STREAM_CREATE`/`STREAM_SERVER_UPDATE` pair — so a client that discards
    /// the first credential can never reconnect to that stream again. Stopping
    /// and starting a watch is an ordinary thing to do, and without this it
    /// works exactly once per stream.
    private var watchCredentials: [UserID: (session: GoLiveSession, server: GoLiveServer)] = [:]

    /// Each person's voice settings as last applied to the call. See
    /// `applyAudioContext`.
    private var appliedAudio: [UserID: AudioContextSettings.Entry] = [:]

    /// Soundboards being fetched, so a picker opened twice asks once.
    private var soundboardFetches: Set<GuildID> = []
    /// Servers asked for by op 31 and not answered yet.
    private var soundboardRequests: Set<GuildID> = []
    /// The reader's plays not yet written into the account's frecency —
    /// Discord's pending usage, put back on top of whatever is read meanwhile.
    private var pendingSoundPlays: [(soundID: String, at: Date)] = []
    private var soundPlayWrite: Task<Void, Never>?
    /// Clips already fetched, by sound id. A soundboard press is a download,
    /// and pressing the same sound twice in a session must not be two.
    private var clipCache: [String: [Float]] = [:]
    private var clipFetches: Set<String> = []
    /// Effects clear themselves; this is the task that does it.
    private var effectTasks: [UserID: Task<Void, Never>] = [:]

    /// The blips a call makes.
    private let sounds = VoiceSoundPlayer()
    /// Discord's stage waiting music, looped under the call — made the first
    /// time a stage plays it and kept for the session (`LoopedTrack`).
    private var stageMusic: LoopedTrack?
    /// Follows `AppModel.stageMusicPlayback`, so the music answers the room
    /// wherever the reader is looking — not only while a stage is on screen.
    private var stageMusicFollower: Task<Void, Never>?
    /// Who is watching our own screen share, as of the last `STREAM_UPDATE`.
    /// The sounds are the **delta** against this — the event carries the whole
    /// set every time.
    private var streamViewerIDs: Set<UserID> = []
    /// True between pressing call and somebody answering. What the ringback
    /// runs on, and what stops it running for a call that was never started.
    private var isRingingOut = false
    /// Discord's Start Video Call: the camera goes on once the call's own
    /// session is up, never before there is somewhere to send it.
    private var startsWithCamera = false
    /// Follows `AppModel.focusedCameraUserID` into the call, whose spotlit
    /// picture is asked for whole.
    private var videoFocusFollower: Task<Void, Never>?
    /// Whether incoming video is wanted: false once every window has been
    /// hidden thirty seconds — Discord's `WindowVisibilityVideoManager`.
    private var isIncomingVideoEnabled = true
    private var hiddenWindowsClock: Task<Void, Never>?
    private var occlusionObserver: (any NSObjectProtocol)?

    /// Watches the handshake and does something about it when it does not
    /// finish. See `armWatchdog`.
    private var watchdog: Task<Void, Never>?
    /// How many times the join has been re-sent for the current channel.
    private var rejoinAttempts = 0
    /// **A handshake that hangs is the failure this protocol produces most
    /// often**, because every way it can fail is silent: a lost op 4, a
    /// `VOICE_SERVER_UPDATE` that arrived while the socket was reconnecting, a
    /// region being reassigned. Twelve seconds is far longer than a working
    /// join, which is under two.
    private static let handshakeTimeout = Duration.seconds(12)

    init(model: AppModel, rest: DiscordREST) {
        self.model = model
        self.rest = rest
        ScreenSourcePicker.shared.onEvent = { [weak self] event in self?.pickerDidAnswer(event) }
        stageMusicFollower = Task { [weak self, weak model] in
            for await playback in Observations({ @MainActor in model?.stageMusicPlayback ?? .stopped }) {
                self?.playStageMusic(playback)
            }
        }
        videoFocusFollower = Task { [weak self, weak model] in
            for await focus in Observations({ @MainActor in model?.focusedCameraUserID }) {
                self?.engine?.setFocusedVideoUser(focus?.rawValue)
            }
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowsDidChangeVisibility() }
        }
    }

    /// Discord's `WindowVisibilityVideoManager`: with every window hidden —
    /// minimised, covered, on another Space, the app hidden — for thirty
    /// seconds, no incoming picture is asked for; a window showing asks again
    /// at once.
    private func windowsDidChangeVisibility() {
        hiddenWindowsClock?.cancel()
        if NSApp.occlusionState.contains(.visible) {
            setIncomingVideoEnabled(true)
        } else {
            hiddenWindowsClock = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.setIncomingVideoEnabled(false)
            }
        }
    }

    private func setIncomingVideoEnabled(_ enabled: Bool) {
        guard isIncomingVideoEnabled != enabled else { return }
        isIncomingVideoEnabled = enabled
        engine?.setIncomingVideoEnabled(enabled)
    }

    /// How big a tile draws somebody's camera. Not our own, and not a share
    /// being watched — those are other sessions' pictures.
    func setDrawnPixels(_ pixels: Int, for userID: UserID) {
        guard userID != model.currentUserID, userID != model.watchedStreamUserID else { return }
        engine?.setDrawnPixels(pixels, for: userID.rawValue)
    }

    /// Plays, pauses or stops the waiting music. Made on its first play — a
    /// reader who never sits in a quiet stage never opens the file.
    private func playStageMusic(_ playback: StageMusic.Playback) {
        if stageMusic == nil {
            // Discord's volume is the output volume over four hundred; the
            // call's render applies the output volume, so this is the quarter.
            guard playback != .stopped,
                  let url = VoiceSound.stageWaitingURL,
                  let track = LoopedTrack(url: url, gain: 0.25)
            else { return }
            stageMusic = track
            engine?.setLoopedTrack(track)
        }
        stageMusic?.setPlayback(playback)
    }

    func attach(socket: GatewaySocket) {
        self.socket = socket
    }

    // MARK: Joining and leaving

    /// Joins a voice channel, or moves between two.
    ///
    /// Moving is the same op with a different channel — there is no leave in
    /// between, and sending one produces an audible drop and a re-ring for
    /// everybody watching the member list.
    func join(channelID: ChannelID, guildID: GuildID?) {
        guard model.connectedVoiceChannelID != channelID else { return }
        Self.log.info("joining voice channel")
        // A video call says so after joining; any other join starts without.
        startsWithCamera = false

        // The old session's media stops before the new one is asked for.
        // Leaving it running gives two engines one output device and one
        // microphone, and the symptom is that the first call is still audible
        // inside the second.
        teardownEngine()
        pendingSession = nil
        pendingServer = nil
        joiningChannelID = channelID
        joiningGuildID = guildID

        model.connectedVoiceChannelID = channelID
        // A new room: nobody's clip flags are known yet, and its own notice.
        model.forgetVoiceClientFlags()
        model.voiceQuality = .idle
        model.spotlightUserID = nil
        model.isVoiceChatShown = guildID != nil
        streamViewerIDs = []
        rejoinAttempts = 0

        // **You are in the call the moment you press join.** The tile for
        // yourself used to wait for the server's own `VOICE_STATE_UPDATE` to
        // come back, so a slow — or broken — handshake showed an *empty* call
        // with a control bar under it, which reads as the feature not working
        // rather than as a connection still being made. The server's answer
        // overwrites this a moment later; until then the client says what it
        // knows, which is that it asked to be here.
        if let userID = model.currentUserID {
            model.voiceStates[userID] = VoiceState(
                userID: userID,
                channelID: channelID,
                guildID: guildID,
                isSelfMuted: model.isSelfMuted,
                isSelfDeafened: model.isSelfDeafened,
                // A stage seats everybody in the audience, moderators too.
                isSuppressed: model.channelIndex[channelID]?.kind == .stage
            )
            model.voiceRevision &+= 1
        }

        // **Before the handshake, not after it.** The sound reports the act,
        // and the act is pressing join; making it wait for a media session
        // that takes a second to negotiate turns instant feedback into lag.
        sounds.play(.join)
        armWatchdog(channelID: channelID, guildID: guildID)
        Task { [socket] in
            await socket?.updateVoiceState(
                guildID: guildID,
                channelID: channelID,
                selfMute: self.model.isSelfMuted,
                selfDeaf: self.model.isSelfDeafened,
                selfVideo: false,
                flags: self.model.announcedVoiceFlags
            )
        }
        loadSoundboard(forGuild: guildID)
    }

    /// Joins a direct-message call somebody is already in, ringing nobody —
    /// with the camera, for Start Video Call on a running call.
    func joinDirectCall(channelID: ChannelID, withCamera: Bool) {
        join(channelID: channelID, guildID: nil)
        startsWithCamera = withCamera
    }

    /// Starts a direct-message call and rings the other side — with the
    /// camera, for Start Video Call.
    func startDirectCall(channelID: ChannelID, withCamera: Bool = false) {
        join(channelID: channelID, guildID: nil)
        startsWithCamera = withCamera
        // The ringback, until they answer, decline, or we give up. All three
        // stop it: a ringtone that outlives its call is the one sound bug
        // everybody notices.
        isRingingOut = true
        sounds.play(.outgoingCall)
        Task { [rest] in
            // The ring is best-effort: a call whose ring failed is still a call
            // the other side can join from the conversation, and failing the
            // join over it would be worse than a phone that did not ring.
            try? await rest.ring(channelID)
        }
    }

    func leave() {
        guard let channelID = model.connectedVoiceChannelID else { return }
        let guildID = model.channelIndex[channelID]?.guildID
        Self.log.info("leaving voice")

        stopRinging()
        startsWithCamera = false
        sounds.play(.voiceDisconnected)
        disarmWatchdog()
        teardownEngine()
        if let userID = model.currentUserID { model.voiceStates[userID] = nil }
        model.connectedVoiceChannelID = nil
        model.isEchoCancellationOff = false
        model.isMicSilent = false
        model.forgetVoiceClientFlags()
        model.speakingUserIDs = []
        model.liveVideoUserIDs = []
        model.voicePlatforms = [:]
        model.isSelfSpeaking = false
        model.isCameraOn = false
        model.isScreenSharing = false
        model.spotlightUserID = nil
        model.isVoiceChatShown = false
        model.voiceQuality = .idle
        model.incomingCallChannelID = nil
        model.voiceRevision &+= 1

        let flags = model.announcedVoiceFlags
        Task { [socket, rest] in
            // A null channel is the leave: there is no leave op.
            await socket?.updateVoiceState(
                guildID: guildID,
                channelID: nil,
                selfMute: false,
                selfDeaf: false,
                flags: flags
            )
            if guildID == nil { try? await rest.stopRinging(channelID) }
        }
    }

    /// Declines a call that is ringing. Distinct from leaving: the other side
    /// is told, so their phone stops.
    func decline(channelID: ChannelID) {
        stopRinging()
        model.incomingCallChannelID = nil
        model.directCalls[channelID] = nil
        Task { [rest] in try? await rest.stopRinging(channelID) }
    }

    // MARK: The handshake watchdog

    /// Re-asks, then gives up, rather than spinning forever.
    ///
    /// **Every way this handshake fails is silent.** Op 4 can be sent into a
    /// socket that is already closing; `VOICE_SERVER_UPDATE` can arrive while
    /// the gateway is reconnecting and be lost with the old session; a region
    /// can be reassigned and the endpoint arrive as null. In every one of those
    /// the client sits at "Connecting" with nothing wrong that it can see,
    /// which is the one failure mode a connection layer must not have.
    ///
    /// So: ask again once, and then say so. **Re-asking is a leave and a join,
    /// not a repeat of the same op** — a server that already believes we are in
    /// the channel treats an identical op 4 as no change and answers nothing,
    /// which is exactly the state we are trying to escape.
    private func armWatchdog(channelID: ChannelID, guildID: GuildID?) {
        disarmWatchdog()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard !Task.isCancelled, let self else { return }
            guard model.connectedVoiceChannelID == channelID,
                  !model.voiceQuality.isConnected else { return }

            guard rejoinAttempts < 1 else {
                Self.log.error("voice handshake never completed; giving up")
                model.reportActionFailure("Could not connect to voice. Try joining again.")
                leave()
                return
            }
            rejoinAttempts += 1
            Self.log.error("voice handshake stalled; re-asking")
            Log.info(.voice, "the voice handshake stalled; asking again")
            resendJoin(channelID: channelID, guildID: guildID)
            armWatchdog(channelID: channelID, guildID: guildID)
        }
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// The leave-then-join that forces a fresh voice server.
    private func resendJoin(channelID: ChannelID, guildID: GuildID?) {
        teardownEngine()
        pendingSession = nil
        pendingServer = nil
        Task { [socket, model] in
            await socket?.updateVoiceState(
                guildID: guildID, channelID: nil, selfMute: false, selfDeaf: false,
                flags: model.announcedVoiceFlags
            )
            // A beat between them: the two frames are processed in order, but
            // the server has to actually drop the old voice state before the
            // new one reads as a change rather than as a repeat.
            try? await Task.sleep(for: .milliseconds(300))
            await socket?.updateVoiceState(
                guildID: guildID,
                channelID: channelID,
                selfMute: model.isSelfMuted,
                selfDeaf: model.isSelfDeafened,
                selfVideo: model.isCameraOn,
                flags: model.announcedVoiceFlags
            )
        }
    }

    /// The main gateway came back.
    ///
    /// **A voice state does not survive a session that died.** The server drops
    /// it, and it never volunteers a new `VOICE_SERVER_UPDATE` for a channel it
    /// thinks nobody asked about — so a call that was up when the socket blipped
    /// stays at "Connecting" for ever unless the client asks again. It is asked
    /// again here, and only when the media session is not already up, so an
    /// ordinary resume that kept everything costs nothing.
    func gatewayDidReconnect() {
        guard let channelID = model.connectedVoiceChannelID else { return }
        guard !model.voiceQuality.isConnected else { return }
        let guildID = model.channelIndex[channelID]?.guildID
        Log.info(.voice, "the gateway came back while voice was down; asking again")
        rejoinAttempts = 0
        resendJoin(channelID: channelID, guildID: guildID)
        armWatchdog(channelID: channelID, guildID: guildID)
    }

    // MARK: Gateway events

    /// Somebody's voice state moved — including ours.
    func apply(state: VoiceState, member: Member?, user: User?) {
        if let user, model.users[user.id] == nil {
            model.users[user.id] = user
            model.identityRevision &+= 1
        }
        if let member, let guildID = state.guildID {
            model.members[guildID, default: [:]][member.userID] = member
            model.memberRevision &+= 1
        }

        // **The sound is about the room the reader is in, and about nobody
        // else's room.** A busy account has people moving between voice
        // channels in ninety servers; a client that played a join for each of
        // them would be a metronome.
        let here = model.connectedVoiceChannelID
        let wasHere = model.voiceStates[state.userID]?.channelID == here && here != nil
        let isHere = state.channelID == here && here != nil

        if state.channelID == nil {
            model.voiceStates[state.userID] = nil
            model.speakingUserIDs.remove(state.userID)
            model.liveVideoUserIDs.remove(state.userID)
        } else {
            model.voiceStates[state.userID] = state
        }

        if state.userID != model.currentUserID, wasHere != isHere {
            // Our own arrival already played when we pressed join, and our own
            // departure plays `voiceDisconnected` instead.
            sounds.play(isHere ? .join : .userLeave)
            // **Somebody arriving is what "answered" means.** A private call
            // has no answer event: the callee simply appears in the channel,
            // and that is the moment the ringback has to stop.
            if isHere { stopRinging() }
        }
        model.voiceRevision &+= 1
        model.sidebarRevision &+= 1

        guard state.userID == model.currentUserID else { return }
        SessionController.trace(
            "own voice state: channel=\(state.channelID?.description ?? "nil") "
            + "session=\(state.sessionID.isEmpty ? "MISSING" : "present")"
        )

        // Our own state. Two things come out of it: the session id the media
        // handshake needs, and the fact that a move happened somewhere else —
        // another device, or a moderator.
        if state.channelID == nil {
            if model.connectedVoiceChannelID != nil { leaveLocally() }
            return
        }
        if state.channelID != joiningChannelID, state.channelID != model.connectedVoiceChannelID {
            // Dragged into another channel by a moderator, or joined from a
            // phone. Follow it rather than arguing with the server.
            joiningChannelID = state.channelID
            joiningGuildID = state.guildID
            model.connectedVoiceChannelID = state.channelID
            teardownEngine()
        }
        pendingSession = state.sessionID
        connectIfReady()
    }

    func apply(server: VoiceServer) {
        Log.info(.voice, "voice server assigned: \(public: server.endpoint)")
        pendingServer = server
        connectIfReady()
    }

    func apply(call: DirectCall) {
        model.directCalls[call.channelID] = call
        // Somebody is ringing us if we are on the list and are not already in
        // the call. Ringing ourselves — which the server does, on the caller's
        // own event — would open an incoming-call sheet over your own call.
        if let selfID = model.currentUserID,
           call.ringingUserIDs.contains(selfID),
           model.connectedVoiceChannelID != call.channelID {
            model.incomingCallChannelID = call.channelID
        } else if model.incomingCallChannelID == call.channelID,
                  !call.ringingUserIDs.contains(model.currentUserID ?? UserID(rawValue: 0)) {
            model.incomingCallChannelID = nil
        }
        model.voiceRevision &+= 1
    }

    func applyCallEnded(_ channelID: ChannelID) {
        if model.connectedVoiceChannelID == channelID { stopRinging() }
        model.directCalls[channelID] = nil
        if model.incomingCallChannelID == channelID { model.incomingCallChannelID = nil }
        if model.connectedVoiceChannelID == channelID { leaveLocally() }
        model.voiceRevision &+= 1
    }

    /// Somebody pressed a soundboard sound.
    ///
    /// **The audio is not in the event.** Every client downloads the clip and
    /// plays it for itself, which is why this is a fetch and a local mix rather
    /// than a stream.
    func apply(effect: VoiceChannelEffect) {
        guard effect.channelID == model.connectedVoiceChannelID else { return }
        guard let soundID = effect.soundID else { return }
        // Discord's Mute Soundboard: their sounds are not played here.
        guard model.audioContext.users[effect.userID]?.isSoundboardMuted != true else { return }

        showEffect(soundID, from: effect.userID)
        let volume = Float(effect.soundVolume) * model.syncedPreferences.soundboardVolume / 100
        Task { [weak self] in
            await self?.playClip(id: soundID, volume: volume)
        }
    }

    /// Who is watching somebody's screen share.
    ///
    /// **Only our own stream makes a sound.** The event arrives for every share
    /// in the channel, and a client that played a chime whenever anybody's
    /// audience changed would be reporting other people's viewers as if they
    /// were yours.
    ///
    /// The payload carries the **whole** viewer set on every update, never a
    /// delta, so the arrivals and departures are the difference against what
    /// was held. Both directions are reported: somebody stopping watching is as
    /// useful to know as somebody starting.
    func applyStreamViewers(owner: UserID, viewers: Set<UserID>) {
        guard owner == model.currentUserID, model.isScreenSharing else { return }
        // Never ourselves: the server lists the streamer among the viewers on
        // some payloads, and a chime for your own stream on every update is a
        // chime nobody can explain.
        let next = viewers.subtracting([owner])
        let previous = streamViewerIDs
        streamViewerIDs = next
        guard previous != next else { return }
        if !next.subtracting(previous).isEmpty {
            sounds.play(.viewerJoin)
            // **A new viewer needs a keyframe, and this is the only notice we
            // get that there is one.** They arrive with no parameter sets and
            // no reference frame, so everything sent until the encoder's next
            // keyframe — up to two seconds — is undecodable to them. This
            // client answers no retransmission requests either, so one they
            // miss is one they never get.
            Task { [stream] in await stream?.requestKeyframe() }
        }
        if !previous.subtracting(next).isEmpty { sounds.play(.viewerLeave) }
    }

    func applyStreamEnded(owner: UserID) {
        guard owner == model.currentUserID else { return }
        streamViewerIDs = []
    }

    func applySoundboard(guildID: GuildID?, sounds catalog: [SoundboardSound]) {
        if let guildID {
            // An empty answer is kept as an empty array: absent means "not
            // asked", and a server with no sounds would be asked every open.
            model.guildSoundboardSounds[guildID] = catalog
            soundboardRequests.remove(guildID)
        } else {
            model.defaultSoundboardSounds = catalog
        }
        model.soundboardRevision &+= 1
    }

    /// The voice states out of `READY_SUPPLEMENTAL`.
    ///
    /// **Assigned, not merged.** These describe the account at the moment this
    /// gateway session was built, and nothing else can have written a voice
    /// state yet — a merge would carry a state from the *previous* session over
    /// a reconnect, which is how somebody stays in a room they left while the
    /// socket was down.
    ///
    /// Our own state is the one exception and it is deliberately included: if
    /// the reader is already in a call on another device, this is what tells the
    /// sidebar so.
    func applyReadySupplemental(voiceStates: [UserID: VoiceState]) {
        guard !voiceStates.isEmpty || !model.voiceStates.isEmpty else { return }
        model.voiceStates = voiceStates
        model.voiceRevision &+= 1
        model.sidebarRevision &+= 1
    }

    /// One guild's voice states, out of a passive update.
    ///
    /// **A delta, and the departures are ids.** This is the one event where
    /// leaving is a bare user id rather than a state with a null channel, so the
    /// two halves are applied separately — reading the removals as states would
    /// leave everybody in the room for ever, which is the same failure a null
    /// channel causes when it is read as "unknown".
    ///
    /// Silent: no join or leave sound. By definition this describes a guild the
    /// reader is not subscribed to, which is every guild except the one on
    /// screen — a sound per arrival across ninety servers is a metronome.
    func applyPassive(
        guildID: GuildID,
        states: [VoiceState],
        departedUserIDs: [UserID],
        members: [UserID: Member],
        users: [UserID: User]
    ) {
        var moved = false
        for userID in departedUserIDs where model.voiceStates[userID] != nil {
            model.voiceStates[userID] = nil
            model.speakingUserIDs.remove(userID)
            model.liveVideoUserIDs.remove(userID)
            moved = true
        }
        for state in states {
            guard state.channelID != nil else {
                if model.voiceStates[state.userID] != nil {
                    model.voiceStates[state.userID] = nil
                    moved = true
                }
                continue
            }
            guard model.voiceStates[state.userID] != state else { continue }
            model.voiceStates[state.userID] = state
            moved = true
        }

        if !members.isEmpty {
            model.members[guildID, default: [:]].merge(members) { _, new in new }
            model.memberRevision &+= 1
        }
        if !users.isEmpty {
            // Merged over, never replaced: a member payload's user carries no
            // bio and no badges, and writing one across a profile-fetched
            // record wipes the card the reader may be looking at.
            model.users.merge(users) { existing, new in new.merged(over: existing) }
            model.identityRevision &+= 1
        }
        guard moved else { return }
        model.voiceRevision &+= 1
        model.sidebarRevision &+= 1
    }

    /// Everything READY said about calls and soundboards.
    func applyReady(
        voiceStates: [UserID: VoiceState],
        soundboards: [GuildID: [SoundboardSound]]
    ) {
        model.voiceStates = voiceStates
        model.voiceRevision &+= 1
        if !soundboards.isEmpty {
            model.guildSoundboardSounds = soundboards
            model.soundboardRevision &+= 1
        }
        Task { [weak self] in await self?.loadDefaultSounds() }
    }

    // MARK: Bringing the media up

    private func connectIfReady() {
        guard let session = pendingSession, let server = pendingServer,
              let userID = model.currentUserID,
              engine == nil
        else {
            SessionController.trace(
                "voice not ready: session=\(pendingSession != nil) "
                + "server=\(pendingServer != nil) engine=\(engine != nil)"
            )
            return
        }
        Log.info(.voice, "voice handshake starting")

        let channel = joiningChannelID.flatMap { model.channelIndex[$0] }
        let engine = MediaSession(
            connection: MediaSession.Connection(
                endpoint: server.endpoint,
                token: server.token,
                serverID: server.serverID,
                userID: userID.rawValue,
                sessionID: session
            ),
            kind: .call(
                // The MLS group DAVE builds is keyed by the **channel**, which
                // in a guild is not the same snowflake as `serverID`.
                channelID: joiningChannelID?.rawValue ?? 0,
                // The channel's own ceiling, never a constant. Discord's mixer
                // drops what exceeds it rather than transcoding, so a client
                // that always encodes at 96k is silent in every unboosted
                // server — which is most of them.
                audioBitrate: channel?.bitrate ?? 64_000,
                preferences: Self.audioPreferences()
            )
        )
        self.engine = engine
        // AirPods' stem press mutes this call from here on.
        adoptSystemMuteGesture()
        // A second engine can't have the microphone, so a note going now stops here.
        model.voiceRecorder.callChanged()
        // The call's side of clips, while clips are on — the plan says whose.
        engine.setClipTap(AppSettings.shared.clipsEnabled ? model.clipRecorder.callTap : nil)
        model.refreshClipCallPlan()
        // What the call asks to receive — VOICE-VIDEO-NOTES §5.5b.
        engine.setIsStage(channel?.kind == .stage)
        engine.setFocusedVideoUser(model.focusedCameraUserID?.rawValue)
        engine.setIncomingVideoEnabled(isIncomingVideoEnabled)
        // **The system's own picker offers this app while there is a call to
        // stream into**, as Discord keeps its picker active in a voice channel —
        // which is also what lets the reader start a share from the menu bar.
        ScreenSourcePicker.shared.isActive = true
        // A new session knows nobody's settings: all of them, once.
        appliedAudio = [:]
        applyAudioContext()
        for userID in AppSettings.shared.disabledVideoUserIDs {
            Task { await engine.setVideoDisabled(true, for: userID) }
        }

        engineTask = Task { [weak self] in
            await engine.start()
            for await event in engine.events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    /// The call's audio settings, as the settings window holds them now.
    private static func audioPreferences() -> MediaSession.AudioPreferences {
        let settings = AppSettings.shared
        var preferences = MediaSession.AudioPreferences()
        preferences.inputDeviceUniqueID = settings.voiceInputDeviceID
        preferences.outputDeviceUniqueID = settings.voiceOutputDeviceID
        preferences.inputVolume = Float(settings.voiceInputVolume)
        preferences.outputVolume = Float(settings.voiceOutputVolume)
        preferences.inputMode = settings.resolvedInputMode
        preferences.processing = settings.resolvedProcessing
        preferences.streamAttenuation = settings.resolvedStreamAttenuation
        return preferences
    }

    private func apply(_ event: MediaSession.Event) {
        switch event {
        case .state(let state):
            switch state {
            case .connected:
                model.voiceQuality.isConnected = true
                disarmWatchdog()
                rejoinAttempts = 0
                // From here the call has a mixer of its own, and a one-shot
                // goes through it: out of the chosen device, and inside the
                // canceller's reference so the far end does not hear it back.
                sounds.callSink = { [weak self] samples, volume in
                    Task { await self?.engine?.playLocalClip(samples, volume: volume) }
                }
                // The waiting music mixes into the call it plays under.
                engine?.setLoopedTrack(stageMusic)
                if startsWithCamera {
                    startsWithCamera = false
                    setCameraOn(true)
                }
            case .failed(let reason):
                Self.log.error("voice failed: \(reason, privacy: .public)")
                Log.fault(.voice, "the call failed: \(public: reason)")
                model.voiceQuality.isConnected = false
                // **Say why.** A call that closes itself a second after it
                // opened, with nothing on screen to say what happened, reads as
                // the feature being broken — which is indistinguishable from
                // the server refusing the session, and only one of those is
                // something the reader can act on.
                model.reportActionFailure(reason)
                leaveLocally()
            case .idle, .connecting:
                model.voiceQuality.isConnected = false
            }

        case .speaking(let userID, let isSpeaking):
            let id = UserID(rawValue: userID)
            // Guarded: a `@State`-equivalent write of an equal value still
            // publishes, and this arrives on every gate change for everybody.
            if isSpeaking {
                guard !model.speakingUserIDs.contains(id) else { return }
                model.speakingUserIDs.insert(id)
            } else {
                guard model.speakingUserIDs.contains(id) else { return }
                model.speakingUserIDs.remove(id)
            }

        case .selfSpeaking(let isOpen):
            guard model.isSelfSpeaking != isOpen else { return }
            model.isSelfSpeaking = isOpen

        case .videoAvailability(let userID, let hasVideo):
            let id = UserID(rawValue: userID)
            if hasVideo {
                guard !model.liveVideoUserIDs.contains(id) else { return }
                model.liveVideoUserIDs.insert(id)
            } else {
                guard model.liveVideoUserIDs.contains(id) else { return }
                model.liveVideoUserIDs.remove(id)
                if model.spotlightUserID == id { model.spotlightUserID = nil }
            }

        case .participantsChanged:
            model.voiceRevision &+= 1

        case .inputLevel(let level):
            // The meter is the only reader and it draws a bar. Publishing a
            // change smaller than it can show is an invalidation for nothing.
            guard abs(model.selfInputLevel - level) > 0.01 else { return }
            model.selfInputLevel = level

        case .statistics(let statistics):
            // **Mutated, not rebuilt.** A memberwise `VoiceQuality(...)` here
            // silently resets every field it does not mention to its default —
            // which is how the encryption badge came to read "not end to end"
            // twice a second on a call that was. Anything this event does not
            // measure has to survive it.
            var next = model.voiceQuality
            next.lossPercent = statistics.lossPercent
            next.jitterMilliseconds = statistics.jitterMilliseconds
            // The grade is what anything draws; the raw numbers are only in the
            // diagnostics pane. Publishing on the numbers would invalidate the
            // HUD twice a second for ever.
            guard next.grade != model.voiceQuality.grade
                || next.lossPercent != model.voiceQuality.lossPercent else { return }
            model.voiceQuality = next

        case .speechWhileMuted:
            guard !model.isTalkingWhileMuted else { return }
            model.isTalkingWhileMuted = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.model.isTalkingWhileMuted = false
            }

        case .encryption(let state):
            let encryption: VoiceQuality.Encryption = switch state {
            case .endToEnd(let code): .endToEnd(verificationCode: code)
            case .establishing: .establishing
            case .transportOnly: .transportOnly
            }
            guard model.voiceQuality.encryption != encryption else { return }
            model.voiceQuality.encryption = encryption

        case .captureEnded:
            // A call captures no screen; a share is a session of its own.
            break

        case .priorityRequested(let userID):
            let may = joiningChannelID.map { model.mayHavePriority(UserID(rawValue: userID), in: $0) } ?? false
            Task { [engine] in await engine?.setMayHavePriority(may, for: userID) }

        case .inputSilent(let isSilent):
            guard model.isMicSilent != isSilent else { return }
            model.isMicSilent = isSilent

        case .echoCancellationUnavailable(let isOff):
            guard model.isEchoCancellationOff != isOff else { return }
            model.isEchoCancellationOff = isOff
            if isOff { Log.info(.voice, "the call is running without echo cancellation") }

        case .clientFlags(let userID, let flags):
            model.noteVoiceClientFlags(VoiceStateFlags(rawValue: flags), for: UserID(rawValue: userID))

        case .platform(let userID, let raw):
            let id = UserID(rawValue: userID)
            guard let platform = VoicePlatform(rawValue: raw), model.voicePlatforms[id] != platform else { return }
            model.voicePlatforms[id] = platform
            model.voiceRevision &+= 1
        }
    }

    /// Ends the media without telling the server, for when the server is what
    /// told us.
    private func leaveLocally() {
        stopRinging()
        // **The same sound whether you left or the server dropped you.** From
        // where the reader is sitting those are one event — the call ended
        // without them ending it — and two sounds for it would be a
        // distinction only the protocol can see.
        sounds.play(.voiceDisconnected)
        disarmWatchdog()
        teardownEngine()
        if let userID = model.currentUserID { model.voiceStates[userID] = nil }
        model.connectedVoiceChannelID = nil
        model.forgetVoiceClientFlags()
        model.speakingUserIDs = []
        model.liveVideoUserIDs = []
        model.voicePlatforms = [:]
        model.isSelfSpeaking = false
        model.isCameraOn = false
        model.isScreenSharing = false
        model.isVoiceChatShown = false
        model.voiceQuality = .idle
        model.voiceRevision &+= 1
    }

    private func teardownEngine() {
        engineTask?.cancel()
        engineTask = nil
        // The call's mixer is going away, so the blips go back to their own
        // engine rather than into a sink nothing is draining.
        sounds.callSink = nil
        // The share and anything being watched go with the call they belong to.
        // Silent here: the caller has already played the one sound this event
        // gets.
        teardownStream()
        discardDraft()
        stopWatchingStream()
        ScreenSourcePicker.shared.isActive = false
        // A stream's credential is only good for the media session it was
        // issued in, and that session goes with the call.
        watchCredentials.removeAll()
        guard let engine else { return }
        releaseSystemMuteGesture()
        self.engine = nil
        // The note was borrowing this call's microphone.
        model.voiceRecorder.callChanged()
        Task { await engine.stop() }
    }

    // MARK: Switches

    func setMuted(_ muted: Bool) {
        guard model.isSelfMuted != muted else { return }
        model.isSelfMuted = muted
        sounds.play(muted ? .mute : .unmute)
        Task { [engine] in await engine?.setMuted(muted) }
        publishSwitches()
        syncSystemMute()
    }

    func setDeafened(_ deafened: Bool) {
        guard model.isSelfDeafened != deafened else { return }
        model.isSelfDeafened = deafened
        // **One sound, not two.** Deafening implies muting, and playing the
        // deafen blip and the mute blip together is two sounds for one press.
        sounds.play(deafened ? .deafen : .undeafen)
        // Deafening implies muting; undeafening does not imply unmuting —
        // somebody who was muted before they deafened stays muted, which is
        // what every voice client does.
        if deafened { model.isSelfMuted = true }
        Task { [engine, watch, model] in
            await engine?.setDeafened(deafened)
            // A watched stream's sound is not decoded for a reader who has
            // deafened, any more than the call's is.
            await watch?.setDeafened(deafened)
            if deafened { await engine?.setMuted(true) }
            _ = model
        }
        publishSwitches()
        syncSystemMute()
    }

    func setPushToTalkHeld(_ held: Bool) {
        Task { [engine] in await engine?.setPushToTalkHeld(held) }
    }

    func setPriorityHeld(_ held: Bool) {
        Task { [engine] in await engine?.setPriorityHeld(held) }
    }

    /// Clips was switched on or off, or the account's allow setting moved:
    /// the call's sound goes to the clip tap or not, and everybody in the call
    /// is told the new flags.
    func clipsSettingsChanged() {
        engine?.setClipTap(AppSettings.shared.clipsEnabled ? model.clipRecorder.callTap : nil)
        stream?.setStreamClipSink(model.clipRecorder.streamClipSink())
        publishSwitches()
    }

    /// Republishes the switches so everybody else's roster shows them.
    ///
    /// **Both halves, every time.** The op replaces the whole state, so sending
    /// only the one that changed clears the other — a client that publishes a
    /// mute without the deafen un-deafens itself for everybody watching.
    private func publishSwitches() {
        guard let channelID = model.connectedVoiceChannelID else { return }
        let guildID = model.channelIndex[channelID]?.guildID
        Task { [socket, model] in
            await socket?.updateVoiceState(
                guildID: guildID,
                channelID: channelID,
                selfMute: model.isSelfMuted,
                selfDeaf: model.isSelfDeafened,
                selfVideo: model.isCameraOn,
                flags: model.announcedVoiceFlags
            )
        }
        // Our own tile reads the store, and the store is what just changed.
        if let selfID = model.currentUserID, var state = model.voiceStates[selfID] {
            state.isSelfMuted = model.isSelfMuted
            state.isSelfDeafened = model.isSelfDeafened
            model.voiceStates[selfID] = state
            model.voiceRevision &+= 1
        }
    }

    // MARK: Camera and screen

    func setCameraOn(_ on: Bool) {
        guard let engine else { return }
        var video = MediaSession.VideoPreferences()
        video.cameraDeviceID = AppSettings.shared.cameraDeviceID
        // **The channel's Video Quality, not a setting of ours.** Discord's
        // camera is 720p scaled to what the room wants ("Auto"), or 720p
        // whatever it wants ("720p"), and a moderator chooses which.
        video.isFullQuality = joiningChannelID
            .flatMap { model.channelIndex[$0]?.videoQualityMode } == VideoQualityMode.full
        Task { [weak self] in
            let ok = await engine.setCameraOn(on, preferences: video)
            guard let self else { return }
            // **After the answer, not before it.** A camera that refuses to
            // start — no permission, a device in use elsewhere — must not have
            // announced itself with a sound first.
            if model.isCameraOn != (ok && on) { sounds.play(ok && on ? .cameraOn : .cameraOff) }
            model.isCameraOn = ok && on
            model.voiceRevision &+= 1
            publishSwitches()
        }
    }

    // MARK: Going live
    //
    // **Picked, previewed, then sent.** The reader picks what to share in the
    // system's picker; the capture starts at once, so the Go Live sheet shows
    // the picture that will be sent; Go Live asks Discord for a stream, and the
    // capture is handed to the stream's session once both halves of its
    // credential are in. Nothing is captured before a pick, and closing the
    // sheet without going live stops the capture — a preview nobody is
    // looking at is somebody's screen being read for nothing.

    /// Opens the Go Live sheet.
    func openGoLive() {
        guard engine != nil, liveShare == nil else { return }
        model.isGoLiveSheetOpen = true
    }

    /// Closes the sheet. A capture that did not go live stops with it.
    func closeGoLive() {
        model.isGoLiveSheetOpen = false
        discardDraft()
    }

    /// The system's picker, for a new share or for the one running.
    func pickScreenSource() {
        ScreenSourcePicker.shared.present(changing: draftShare ?? liveShare?.capture)
    }

    /// Where the sheet's preview draws.
    func setGoLivePreviewSink(_ sink: (@Sendable (CMSampleBuffer) -> Void)?) {
        goLivePreviewSink = sink
        guard let draftShare else { return }
        draftShare.route(draftOutputs(for: draftShare))
    }

    /// Discord's Stream Quality and Share Audio, before going live or during.
    func updateGoLive(_ settings: GoLiveSettings) {
        AppSettings.shared.goLive = settings
        let quality = shareQuality()
        if let stream {
            liveShare?.quality = quality
            Task { await stream.updateShare(quality: quality) }
        } else if let capture = liveShare?.capture ?? draftShare {
            liveShare?.quality = quality
            Task {
                do {
                    try await capture.update(quality: quality)
                } catch {
                    Log.fault(.share, "share quality refused: \(error)")
                }
            }
        }
    }

    private func pickerDidAnswer(_ event: ScreenSourcePicker.Event) {
        switch event {
        case .picked(let source, _):
            model.screenShareSource = ScreenShareSourceSummary(source)
            if let stream {
                // Discord's Change Windows, on a share that is live.
                Task { await stream.changeShare(source: source) }
            } else if let capture = liveShare?.capture ?? draftShare {
                Task { [weak self] in
                    do {
                        try await capture.update(source: source)
                    } catch {
                        self?.model.goLivePreview = .failed(error.localizedDescription)
                    }
                }
            } else {
                // **A pick from the menu bar, with no sheet open, goes live at
                // once** — Discord's own answer to a pick its picker reported
                // while its Go Live modal was closed.
                startDraft(source, goesLive: !model.isGoLiveSheetOpen)
            }
        case .cancelled:
            break
        case .failed(let message):
            if model.isGoLiveSheetOpen {
                model.goLivePreview = .failed(message)
            } else {
                model.reportActionFailure(message)
            }
        }
    }

    /// Starts capturing a picked source for the sheet's preview.
    private func startDraft(_ source: ShareSource, goesLive: Bool) {
        guard engine != nil, liveShare == nil, draftShare == nil else { return }
        let capture = ScreenShareCapture()
        draftShare = capture
        model.goLivePreview = .starting
        capture.route(draftOutputs(for: capture))
        let quality = shareQuality()
        Task { [weak self] in
            do {
                try await capture.start(source: source, quality: quality)
            } catch {
                guard let self, self.draftShare === capture else { return }
                self.draftShare = nil
                self.model.goLivePreview = .failed(error.localizedDescription)
                return
            }
            guard let self, self.draftShare === capture else {
                // Closed while it was starting.
                await capture.stop()
                return
            }
            self.model.goLivePreview = .previewing
            if goesLive { self.goLive() }
        }
    }

    /// The draft's outputs: the sheet's preview, and word if it stops.
    private func draftOutputs(for capture: ScreenShareCapture) -> ScreenShareCapture.Outputs {
        ScreenShareCapture.Outputs(
            preview: goLivePreviewSink,
            stopped: { [weak self] reason in
                Task { @MainActor in self?.draftDidStop(capture, reason: reason) }
            }
        )
    }

    private func draftDidStop(_ capture: ScreenShareCapture, reason: String) {
        guard draftShare === capture else { return }
        draftShare = nil
        model.screenShareSource = nil
        model.goLivePreview = .empty
        Log.info(.share, "share preview stopped: \(public: reason)")
    }

    private func discardDraft() {
        if let draftShare { Task { await draftShare.stop() } }
        draftShare = nil
        model.goLivePreview = .empty
        if liveShare == nil { model.screenShareSource = nil }
    }

    /// The Go Live choices this account and this server allow, as the capture
    /// takes them.
    private func shareQuality() -> ScreenShareCapture.Quality {
        let settings = model.goLiveGate.admit(AppSettings.shared.goLive)
        let box = settings.resolution.box
        return ScreenShareCapture.Quality(
            width: box.width, height: box.height,
            framerate: settings.frameRate.rawValue,
            capturesAudio: settings.sharesAudio
        )
    }

    /// Asks Discord for a stream for the previewed capture, and waits for the
    /// two halves of its credential.
    func goLive() {
        guard let capture = draftShare, engine != nil, stream == nil,
              let channelID = joiningChannelID
        else { return }
        draftShare = nil
        model.isGoLiveSheetOpen = false
        model.goLivePreview = .empty
        // The sheet's preview goes with the sheet; the self tile takes the
        // picture once the session routes it.
        capture.route(ScreenShareCapture.Outputs(stopped: { [weak self] reason in
            Task { @MainActor in
                Log.info(.share, "stream capture ended: \(public: reason)")
                self?.stopScreenShare()
            }
        }))
        liveShare = (capture, shareQuality())
        pendingStreamKey = nil
        pendingStreamSession = nil
        pendingStreamServer = nil
        // **No preferred region.** Discord's own client sends the region the
        // call is already in; nothing here holds that value, and §"a field
        // invented for a wire protocol is a field the server may refuse the
        // whole frame over" says to omit it rather than guess. The key is
        // omitted entirely when nil, so the server picks.
        Task { [socket, joiningGuildID] in
            await socket?.createStream(
                guildID: joiningGuildID, channelID: channelID, preferredRegion: nil
            )
        }
    }

    func stopScreenShare() {
        let wasSharing = model.isScreenSharing
        teardownStream()
        if wasSharing { sounds.play(.streamEnd) }
        model.isScreenSharing = false
        model.voiceRevision &+= 1
    }

    /// Ends the stream session and tells the server, without touching the model
    /// or making a sound.
    ///
    /// **Separate from `stopScreenShare` because leaving a call must do this
    /// too.** A share left running after the call it belonged to is a second
    /// websocket, a second UDP socket, and — the part that actually matters —
    /// **somebody's screen still being read** with nothing on screen saying so.
    private func teardownStream() {
        let key = pendingStreamKey
        let share = liveShare
        liveShare = nil
        if stream == nil, let share {
            // Asked for and never connected: nothing took the capture over.
            Task { await share.capture.stop() }
        }
        model.screenShareSource = nil
        pendingStreamKey = nil
        pendingStreamSession = nil
        pendingStreamServer = nil
        streamViewerIDs = []
        streamTask?.cancel(); streamTask = nil
        guard let session = stream else { return }
        stream = nil
        model.clipRecorder.streamDidStop()
        model.refreshOverlay()
        // Told to the server: a stream torn down without opcode 19 stays in the
        // channel's state until it times out, and the far end keeps being
        // offered something to watch that no longer exists.
        if let key { Task { [socket] in await socket?.deleteStream(streamKey: key) } }
        Task { await session.stop() }
    }

    /// `STREAM_CREATE` — the key and the RTC ids.
    ///
    /// **Two streams can be pending at once and they are told apart by owner.**
    /// Ours is the share we asked to publish; somebody else's is the one we
    /// asked to watch. Nothing else about the frame distinguishes them.
    func applyStreamCreated(owner: UserID, key: String, session: GoLiveSession?) {
        if owner == model.currentUserID {
            guard liveShare != nil else { return }
            pendingStreamKey = key
            if let session { pendingStreamSession = session }
            startStreamIfReady()
        } else {
            guard pendingWatch?.owner == owner else { return }
            if let session { pendingWatchSession = session }
            rememberWatchCredential(for: owner)
            startWatchIfReady()
        }
    }

    /// `STREAM_SERVER_UPDATE` — the endpoint and the token.
    ///
    /// Routed by **key**, because this frame does not say whose stream it
    /// describes beyond that.
    func apply(streamServer server: GoLiveServer) {
        if let pending = pendingWatch, pending.key == server.streamKey {
            pendingWatchServer = server
            rememberWatchCredential(for: pending.owner)
            startWatchIfReady()
            return
        }
        guard liveShare != nil else { return }
        pendingStreamServer = server
        pendingStreamKey = server.streamKey
        startStreamIfReady()
    }

    /// Asks to watch somebody's screen share.
    ///
    /// **The key is built rather than received.** Nothing dispatches a stream
    /// event to somebody who is not already watching, so a viewer never learns
    /// the owner's key before asking for it — see `GoLiveKey`.
    func watchStream(owner: UserID) {
        guard watch == nil, pendingWatch == nil,
              let channelID = joiningChannelID,
              owner != model.currentUserID
        else { return }
        let key = GoLiveKey.make(
            guildID: joiningGuildID, channelID: channelID, userID: owner
        )
        pendingWatch = (owner, key)
        model.watchedStreamUserID = owner
        model.voiceRevision &+= 1

        // Already asked once this call: reconnect on what we were given rather
        // than on a second request the server will not answer.
        if let held = watchCredentials[owner] {
            pendingWatchSession = held.session
            pendingWatchServer = held.server
            startWatchIfReady()
            return
        }
        pendingWatchSession = nil
        pendingWatchServer = nil
        Task { [socket] in await socket?.watchStream(streamKey: key) }
    }

    func stopWatchingStream() {
        pendingWatch = nil
        pendingWatchSession = nil
        pendingWatchServer = nil
        watchTask?.cancel(); watchTask = nil
        let session = watch
        watch = nil
        engine?.setStreamAudio(nil)
        // **The credentials outlive this, on purpose** — see
        // `watchCredentials`. They are cleared with the call, in `teardownEngine`.
        model.watchedStreamUserID = nil
        model.liveVideoUserIDs = model.liveVideoUserIDs.filter { $0 != model.currentUserID }
        model.voiceRevision &+= 1
        if session != nil { Task { await session?.stop() } }
    }

    private func rememberWatchCredential(for owner: UserID) {
        guard let session = pendingWatchSession, let server = pendingWatchServer else { return }
        watchCredentials[owner] = (session, server)
    }

    private func startWatchIfReady() {
        guard let pending = pendingWatch,
              let created = pendingWatchSession,
              let server = pendingWatchServer,
              let userID = model.currentUserID,
              let sessionID = pendingSession,
              watch == nil
        else { return }

        let session = MediaSession(
            connection: MediaSession.Connection(
                endpoint: server.endpoint,
                token: server.token,
                // The same pairing a stream we publish uses: the RTC server
                // identifies the session, the RTC channel keys its group.
                serverID: String(created.rtcServerID),
                userID: userID.rawValue,
                sessionID: sessionID
            ),
            kind: .watch(mediaSessionID: created.rtcChannelID, owner: pending.owner.rawValue)
        )
        watch = session
        session.setVideoSink(watchSink, for: pending.owner.rawValue)
        // **Its sound plays through the call**, on the reader's device and
        // inside the echo canceller's reference — see `MediaSession.streamAudio`.
        engine?.setStreamAudio(session.streamAudio)
        engine?.setStreamVolume(streamGain(of: pending.owner))
        if model.isSelfDeafened { Task { await session.setDeafened(true) } }

        watchTask = Task { [weak self] in
            await session.start()
            for await event in session.events {
                guard let self else { return }
                self.apply(watchEvent: event, owner: pending.owner)
            }
        }
    }

    private func apply(watchEvent event: MediaSession.Event, owner: UserID) {
        switch event {
        case .videoAvailability(_, hasVideo: true):
            // **Announced is not arriving.** The tile switches to video on the
            // first packet of the picture that actually arrived, never on the
            // connection.
            guard !model.liveVideoUserIDs.contains(owner) else { return }
            model.liveVideoUserIDs.insert(owner)
            model.voiceRevision &+= 1

        case .state(.failed(let reason)):
            Log.fault(.share, "watching a stream failed: \(public: reason)")
            model.reportActionFailure(reason)
            stopWatchingStream()

        default:
            // A watch has no microphone and no roster the app keeps; the rest
            // is the call's to report.
            break
        }
    }

    private func startStreamIfReady() {
        guard let share = liveShare,
              let server = pendingStreamServer,
              let created = pendingStreamSession,
              let userID = model.currentUserID,
              let sessionID = pendingSession,
              stream == nil
        else {
            SessionController.trace(
                "stream not ready: share=\(liveShare != nil) "
                + "server=\(pendingStreamServer != nil) create=\(pendingStreamSession != nil)"
            )
            return
        }

        // **The RTC server identifies it; the RTC channel keys its group.**
        // Measured — the DM channel and the RTC channel are each refused 4006 —
        // and the two fields turn out to be named for exactly what they are, in
        // the same pairing the call uses: a call identifies with its *server*
        // and keys its group on its *channel*.
        let session = MediaSession(
            connection: MediaSession.Connection(
                endpoint: server.endpoint,
                token: server.token,
                serverID: String(created.rtcServerID),
                userID: userID.rawValue,
                sessionID: sessionID
            ),
            kind: .stream(
                mediaSessionID: created.rtcChannelID,
                capture: share.capture,
                quality: share.quality,
                audioBitrate: joiningChannelID.flatMap { model.channelIndex[$0]?.bitrate } ?? 64_000
            )
        )
        stream = session
        session.setVideoSink(streamPreviewSink, for: userID.rawValue)
        // Clips come off this stream while it runs — Discord's STREAMER
        // source — and the game's own capture stands down.
        model.clipRecorder.streamDidStart()
        session.setStreamClipSink(model.clipRecorder.streamClipSink())
        model.refreshOverlay()

        streamTask = Task { [weak self] in
            await session.start()
            for await event in session.events {
                guard let self else { return }
                self.apply(streamEvent: event)
            }
        }
    }

    private func apply(streamEvent event: MediaSession.Event) {
        switch event {
        case .state(.connected):
            guard !model.isScreenSharing else { return }
            sounds.play(.streamStart)
            model.isScreenSharing = true
            model.voiceRevision &+= 1

        case .state(.failed(let reason)):
            Log.fault(.share, "the stream failed: \(public: reason)")
            // Said out loud, for the reason a failed call is: a share that
            // stops a second after it started, with nothing on screen to say
            // why, reads as the feature being broken.
            model.reportActionFailure(reason)
            stopScreenShare()

        case .encryption(let state):
            // **The stream's own group, and therefore its own code**, which is
            // not the call's — showing the call's shield beside a share would
            // be a claim about the wrong session.
            //
            // There is no surface for it yet, and §5.5 forbids storing a fact
            // the app then draws nowhere, so it goes to the trace: that is
            // where "is this share actually end-to-end encrypted" gets
            // answered until a shield of its own exists.
            // The state's word only: an end-to-end state carries its verification code.
            Log.info(.share, "stream encryption: \(public: state.logWord)")

        case .captureEnded(let reason):
            Log.info(.share, "stream capture ended: \(public: reason)")
            stopScreenShare()

        default:
            // A share sends a picture and nothing else: no voice, no roster the
            // app keeps, nobody's picture to show.
            break
        }
    }

    /// The camera's own session, for the self-view. Never the encoded frames —
    /// a preview layer is a separate hardware path with no round trip.
    func cameraSession() async -> CaptureSessionHandle? {
        await engine?.cameraSession
    }

    /// Where a person's decoded video should be drawn. Cleared when the tile
    /// goes away, which is what stops a display layer being fed after it has
    /// left the window.
    func setVideoSink(_ sink: (@Sendable (CMSampleBuffer) -> Void)?, for userID: UserID) {
        // **Our own tile is never an inbound stream.** A camera's self-view is
        // the capture session's preview layer and never reaches here; a screen
        // share's picture comes from the stream session, which is a different
        // media session altogether. The sink is kept either way, because the
        // tile attaches before a share exists.
        guard userID != model.currentUserID else {
            streamPreviewSink = sink
            stream?.setVideoSink(sink, for: userID.rawValue)
            return
        }
        // Somebody whose **stream** we are watching is on a media session of
        // its own, and their camera on the call is not. One person can be both
        // at once, and the stream is what the tile was opened to show.
        if userID == model.watchedStreamUserID {
            watchSink = sink
            watch?.setVideoSink(sink, for: userID.rawValue)
            return
        }
        engine?.setVideoSink(sink, for: userID.rawValue)
    }

    // MARK: Each person's sound

    /// The account's per-person settings, onto the call as it stands: every
    /// voice's volume and mute, and the watched stream's own level.
    ///
    /// **Diffed against what was last applied**, so a person put back to the
    /// default — whose entry Discord removes rather than writes — is put back
    /// in the call too.
    func applyAudioContext() {
        guard let engine else { return }
        let settings = model.audioContext
        let everybody = Set(settings.users.keys).union(appliedAudio.keys)
        for userID in everybody {
            let entry = settings.users[userID]
            guard entry != appliedAudio[userID] else { continue }
            let volume = Float(entry?.volume ?? AudioContextSettings.Context.user.defaultVolume)
            let isMuted = entry?.isMuted ?? false
            Task {
                await engine.setVolume(volume, forUser: userID.rawValue)
                await engine.setLocallyMuted(isMuted, for: userID.rawValue)
            }
        }
        appliedAudio = settings.users
        // The tiles draw who is muted by the reader.
        model.voiceRevision &+= 1
        if let owner = model.watchedStreamUserID {
            engine.setStreamVolume(streamGain(of: owner))
        }
    }

    /// A stream's own level: its volume, or nothing while it is muted.
    private func streamGain(of owner: UserID) -> Float {
        let settings = model.audioContext
        return settings.isMuted(owner, in: .stream) ? 0 : Float(settings.volume(of: owner, in: .stream))
    }

    /// Discord's Disable Video, for one person.
    func setVideoDisabled(_ disabled: Bool, userID: UserID) {
        Task { [engine] in await engine?.setVideoDisabled(disabled, for: userID.rawValue) }
    }

    /// Applies a change made in the settings window to a call already running.
    func applyPreferences() {
        let preferences = Self.audioPreferences()
        Task { [engine] in await engine?.updatePreferences(preferences) }
        // The blips follow the device too, or a reader who moved Wingcord's
        // output to a headset still hears them out of the laptop.
        sounds.outputDeviceChanged()
    }

    // MARK: The soundboard

    func press(_ sound: SoundboardSound) {
        guard let channelID = model.connectedVoiceChannelID else { return }
        let home = model.channelIndex[channelID]?.guildID
        guard SoundboardGate.canPlay(
            sound,
            playsEverywhere: model.entitlements.has(.soundboardEverywhere),
            inGuild: home,
            mayUseExternalSounds: model.permissionGate.permissions(in: channelID).contains(.useExternalSounds)
        ) else {
            return
        }
        Task { [rest] in try? await rest.sendSoundboardSound(sound, in: channelID) }
        trackSoundPlay(sound.id)
    }

    /// Discord's `SOUNDBOARD_TRACK_USAGE`: Frequently Used moves at once, and
    /// the play is written into the account's frecency ten seconds after the
    /// last one, so a run of presses is one write.
    private func trackSoundPlay(_ soundID: String) {
        let now = Date.now
        pendingSoundPlays.append((soundID, now))
        if var played = model.soundFrecency {
            played.track(soundID, at: now)
            model.soundFrecency = played
            model.soundboardFrequentSoundIDs = played.frequently
        }
        soundPlayWrite?.cancel()
        soundPlayWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            let plays = pendingSoundPlays
            pendingSoundPlays.removeAll()
            do {
                let played = try await rest.recordPlayedSounds(plays)
                model.soundFrecency = played
                model.soundboardFrequentSoundIDs = played.frequently
            } catch {
                // Kept for the next write, as Discord keeps its pending usage
                // until a save lands.
                pendingSoundPlays = plays + pendingSoundPlays
                SessionController.trace("played-sound frecency write failed: \(error)")
            }
        }
    }

    /// Discord's Preview: the sound played here and nowhere else, at the
    /// reader's Soundboard Volume.
    func preview(_ sound: SoundboardSound) {
        let volume = Float(sound.volume) * model.syncedPreferences.soundboardVolume / 100
        Task { [weak self] in await self?.playClip(id: sound.id, volume: volume) }
    }

    /// What the picker draws that is not here yet, asked for as Discord's
    /// picker asks when it opens:
    ///
    /// - Discord's own sounds;
    /// - every server's soundboard not yet read, in **one** op 31
    ///   (`REQUEST_SOUNDBOARD_SOUNDS`), answered per server by
    ///   `SOUNDBOARD_SOUNDS` — the call's own server by REST as well, so its
    ///   section never waits on the gateway;
    /// - the account's favourites and its most-played sounds.
    func soundboardDidOpen() {
        Task { [weak self] in await self?.loadDefaultSounds() }
        if let home = model.connectedVoiceChannelID.flatMap({ model.channelIndex[$0] })?.guildID {
            loadSoundboard(inGuild: home)
        }
        let wanted = model.orderedGuildIDs.filter {
            model.guildSoundboardSounds[$0] == nil
                && !soundboardFetches.contains($0) && !soundboardRequests.contains($0)
        }
        if !wanted.isEmpty, let socket {
            soundboardRequests.formUnion(wanted)
            Task { await socket.requestSoundboardSounds(guildIDs: wanted) }
        }
        Task { [weak self, rest] in
            guard let frecency = try? await rest.soundboardFrecency(), let self else { return }
            model.soundboardFavorites = frecency.favorites
            // Plays not yet written go back on top, as Discord's do.
            var played = frecency.played
            for play in pendingSoundPlays { played.track(play.soundID, at: play.at) }
            model.soundFrecency = played
            model.soundboardFrequentSoundIDs = played.frequently
        }
    }

    /// Discord's star. The model moves first; the write is applied to the
    /// blob as it stands, and a refusal puts the star back.
    func setFavoriteSound(_ soundID: String, favorite: Bool) {
        guard let id = UInt64(soundID) else { return }
        let previous = model.soundboardFavorites
        var next = previous
        if favorite {
            guard next.add(id) else {
                model.reportActionFailure("You cannot have more than \(SoundboardFavorites.limit) favorites.")
                return
            }
        } else {
            next.remove(id)
        }
        model.soundboardFavorites = next
        Task { [weak self, rest] in
            do {
                let written = try await rest.setFavoriteSound(id, favorite: favorite)
                guard let self else { return }
                if let written {
                    model.soundboardFavorites = written
                } else {
                    // Another client filled the list since this one read it.
                    model.soundboardFavorites = previous
                    model.reportActionFailure("You cannot have more than \(SoundboardFavorites.limit) favorites.")
                }
            } catch {
                self?.model.soundboardFavorites = previous
            }
        }
    }

    private func loadDefaultSounds() async {
        guard model.defaultSoundboardSounds.isEmpty else { return }
        guard let sounds = try? await rest.defaultSoundboardSounds() else { return }
        model.defaultSoundboardSounds = sounds
        model.soundboardRevision &+= 1
    }

    /// Fetches one server's soundboard by REST, once — the call's own server
    /// when the picker opens, so its section never waits on the gateway.
    ///
    /// Every other server comes in the one op 31 `soundboardDidOpen` sends,
    /// which is Discord's own picker's request. An earlier note here blamed
    /// that opcode for a stuck socket; its payload had not been read out of
    /// Discord's client then, and now is (`GatewaySocket.requestSoundboardSounds`).
    private func loadSoundboard(inGuild guildID: GuildID) {
        guard model.guildSoundboardSounds[guildID] == nil,
              !soundboardFetches.contains(guildID) else { return }
        soundboardFetches.insert(guildID)
        Task { [weak self, rest] in
            defer { self?.soundboardFetches.remove(guildID) }
            guard let sounds = try? await rest.soundboardSounds(inGuild: guildID) else { return }
            guard let self else { return }
            // An empty answer is stored as an **empty array**, not left absent:
            // absent means "not asked", so a server with no sounds would be
            // asked again every time the picker was opened.
            model.guildSoundboardSounds[guildID] = sounds
            model.soundboardRevision &+= 1
        }
    }

    private func loadSoundboard(forGuild guildID: GuildID?) {
        Task { [weak self] in
            await self?.loadDefaultSounds()
            guard let self, let guildID, model.guildSoundboardSounds[guildID] == nil else {
                return
            }
            guard let sounds = try? await rest.soundboardSounds(inGuild: guildID) else { return }
            model.guildSoundboardSounds[guildID] = sounds
            model.soundboardRevision &+= 1
        }
    }

    /// Ends the ringback, wherever the call went.
    private func stopRinging() {
        guard isRingingOut else { return }
        isRingingOut = false
        sounds.stopRinging()
    }

    private func showEffect(_ soundID: String, from userID: UserID) {
        effectTasks[userID]?.cancel()
        model.soundboardEffects[userID] = soundID
        effectTasks[userID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.model.soundboardEffects[userID] = nil
        }
    }

    private func playClip(id: String, volume: Float) async {
        if let cached = clipCache[id] {
            await engine?.playLocalClip(cached, volume: volume, isSoundboard: true)
            return
        }
        guard !clipFetches.contains(id) else { return }
        clipFetches.insert(id)
        defer { clipFetches.remove(id) }

        guard let data = try? await rest.soundboardClip(id: id) else { return }
        guard let samples = await SoundboardDecoder.decode(data) else { return }
        // A soundboard clip is a couple of seconds of 48 kHz stereo — under a
        // megabyte — and there are a few dozen of them at most. Kept for the
        // session, because the alternative is a download every press.
        clipCache[id] = samples
        await engine?.playLocalClip(samples, volume: volume, isSoundboard: true)
    }
}
