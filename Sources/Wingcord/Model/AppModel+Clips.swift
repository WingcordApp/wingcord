import AVFoundation
import Foundation
import WingcordCore
import WingcordVoice

// MARK: - Clips and the call
//
// docs/CLIPS-PRESENCE.md, Phase 3.2. Discord's consent model, read out of its
// `ClipsManager` and `ConnectionStore` (web build 641803):
//
//   * Every voice state carries `flags`: `ALLOW_VOICE_RECORDING` from the
//     account's "Allow my voice to be recorded in Clips" (on unless switched
//     off), `CLIPS_ENABLED` while clips are on.
//   * The voice server hands each client's flags to everybody else (voice op
//     18). A clip keeps **somebody else's voice only when their flags allow
//     it**, the reader's own whenever clips are on, nobody's in a stage, and
//     the soundboard.
//   * Somebody in the call with clips on, and the reader's own setting
//     allowing recording: **one notice per channel** — "A participant in the
//     call you joined has clipping enabled, your voice may be recorded."

extension AppModel {

    /// Discord's en-US `d+41qJ`.
    static let clipsCallWarning = "A participant in the call you joined has clipping enabled, your voice may be recorded."

    /// What this client says about clips in its voice state — Discord's
    /// `computeVoiceFlags()`.
    var announcedVoiceFlags: VoiceStateFlags {
        .announced(
            allowsVoiceRecording: syncedPreferences.allowsVoiceRecordingInClips,
            clipsEnabled: AppSettings.shared.clipsEnabled
        )
    }

    /// Whose sound the call keeps for clips, from the rules above. Called when
    /// clips, the call, or anybody's flags change.
    func refreshClipCallPlan() {
        let tap = clipRecorder.callTap
        let settings = AppSettings.shared
        guard settings.clipsEnabled else {
            tap.setPlan(.nothing)
            return
        }
        let window = settings.clipLength.seconds + 3
        guard let channelID = connectedVoiceChannelID else {
            // Out of a call nothing new arrives, and what was kept stays for
            // its window — a clip saved just after leaving still has the call.
            var plan = tap.plan
            plan.window = window
            tap.setPlan(plan)
            return
        }
        let isStage = channelIndex[channelID]?.kind == .stage
        let inRoom = Set(voiceStates(in: channelID).map(\.userID))
        let voices: Set<UInt64> = isStage ? [] : Set(voiceClientFlags.compactMap { userID, flags in
            userID != currentUserID && inRoom.contains(userID) && flags.contains(.allowsVoiceRecording)
                ? userID.rawValue : nil
        })
        tap.setPlan(.init(window: window, voices: voices, keepsMicrophone: !isStage, keepsSoundboard: true))
    }

    /// Somebody's client said what it does about clips.
    func noteVoiceClientFlags(_ flags: VoiceStateFlags, for userID: UserID) {
        guard voiceClientFlags[userID] != flags else { return }
        voiceClientFlags[userID] = flags
        refreshClipCallPlan()
        maybeShowClipsWarning(about: userID)
    }

    /// Discord's `maybeShowClipsWarning`: once per channel, about somebody
    /// else with clips on, and only while the reader allows their voice to be
    /// recorded — a reader who does not is not being recorded.
    func maybeShowClipsWarning(about userID: UserID) {
        guard let channelID = connectedVoiceChannelID,
              clipsWarningChannelID != channelID,
              userID != currentUserID,
              voiceClientFlags[userID]?.contains(.clipsEnabled) == true,
              syncedPreferences.allowsVoiceRecordingInClips
        else { return }
        clipsWarningChannelID = channelID
        reportClipsNotice(Self.clipsCallWarning)
    }

    /// The call ended, or moved: nobody's flags are known any more, and the
    /// next channel gets its own notice.
    func forgetVoiceClientFlags() {
        voiceClientFlags = [:]
        clipsWarningChannelID = nil
        refreshClipCallPlan()
    }

    /// Clips was switched on or off, or its length or quality changed.
    func clipsSettingsChanged() {
        if !AppSettings.shared.clipsEnabled {
            Task { await clipRecorder.forgetEverything() }
        }
        refreshClipCallPlan()
        sessionController.voice.clipsSettingsChanged()
        refreshOverlay()
    }

    /// "Allow my voice to be recorded in Clips" — the account's, synced, and
    /// announced at once in the voice state.
    func setAllowsVoiceRecordingInClips(_ allows: Bool) {
        let previous = syncedPreferences
        guard previous.allowsVoiceRecordingInClips != allows else { return }
        syncedPreferences.allowsVoiceRecordingInClips = allows
        // `--demo` asks Discord nothing.
        if !LaunchOptions.current.usesDemoFixtures {
            sessionController.writeSyncedPreference(.allowsVoiceRecordingInClips(allows), restoring: previous)
        }
        sessionController.voice.clipsSettingsChanged()
        // Discord's `handleClipsAllowVoiceRecordingUpdate`: everybody in the
        // call is looked at again.
        if allows, let channelID = connectedVoiceChannelID {
            for state in voiceStates(in: channelID) { maybeShowClipsWarning(about: state.userID) }
        }
    }

    /// How many people in the reader's call have clips on, for Settings › Clips.
    var callMembersClipping: Int {
        guard let channelID = connectedVoiceChannelID else { return 0 }
        return voiceStates(in: channelID).count {
            $0.userID != currentUserID && voiceClientFlags[$0.userID]?.contains(.clipsEnabled) == true
        }
    }

    /// Who is who, for a clip saved now.
    func clipSaveContext() -> ClipRecorder.Context {
        let guildID = connectedVoiceChannelID.flatMap { channelIndex.guildID(of: $0) }
        var names: [UInt64: String] = [:]
        var avatars: [UInt64: URL] = [:]
        var members: [UInt64] = []
        var everyone = Set(clipRecorder.callTap.snapshot().voices.keys)
        if let me = currentUserID { everyone.insert(me.rawValue) }
        if let channelID = connectedVoiceChannelID {
            for state in voiceStates(in: channelID) {
                members.append(state.userID.rawValue)
                everyone.insert(state.userID.rawValue)
            }
        }
        for raw in everyone {
            let userID = UserID(rawValue: raw)
            names[raw] = voiceName(of: userID, inGuild: guildID)
            if let user = users[userID], let url = avatarURL(for: user, side: 64) { avatars[raw] = url }
        }
        return ClipRecorder.Context(
            selfUserID: currentUserID?.rawValue,
            names: names,
            avatars: avatars,
            callMembers: members,
            game: detectedGame.map { ClipGame(applicationID: $0.id.rawValue, name: $0.name) },
            gameEvents: gameEvents.kept
        )
    }
}

// MARK: - Sharing clips (Phase 4.4)

extension AppModel {

    /// Whether a share can go out — a session to send it on, or the demo's
    /// own transcript to land in.
    var canShareClips: Bool {
        connectionState == .ready
    }

    /// Discord's Share for clips: each item exported with its edits, fitted
    /// under the smallest upload limit among `targets`, then sent to each as
    /// one message — a clip with its clip fields, a recording as a video, a
    /// screenshot as a picture. Ten at most, Discord's own ceiling.
    ///
    /// - Parameter reference: the message this answers — a point of view
    ///   added to a clip already shared is a reply to it, as Discord's is
    ///   (`is_distributed_clip_reply`).
    func shareClips(
        _ items: [ClipLibraryItem], to targets: [ChannelID], comment: String,
        replyingTo reference: MessageReference? = nil
    ) {
        let permitted = targets.filter { permissionGate.canSend(in: $0) }
        let items = Array(items.prefix(ClipLibraryStore.shareLimit))
        guard !permitted.isEmpty, !items.isEmpty else { return }
        let limit = permitted.map(uploadLimit(in:)).min()
        let words = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        reportScheduling(items.count == 1 ? "Getting the clip ready…" : "Getting \(items.count) clips ready…")
        Task {
            var files: [PendingAttachment] = []
            for item in items {
                do {
                    files.append(try await Self.prepare(item, maxBytes: limit))
                } catch {
                    reportActionFailure(error.localizedDescription)
                    return
                }
            }
            for target in permitted {
                if LaunchOptions.current.usesDemoFixtures {
                    echoDemoShare(files, comment: words, in: target, replyingTo: reference)
                } else {
                    sessionController.send(words, in: target, replyingTo: reference?.messageID, attachments: files)
                }
            }
        }
    }

    /// One item as the file that goes up.
    private static func prepare(_ item: ClipLibraryItem, maxBytes: Int?) async throws -> PendingAttachment {
        switch item.kind {
        case .screenshot:
            return PendingAttachment(url: item.url)
        case .clip, .recording:
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Wingcord Shares", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = item.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            let destination = folder.appendingPathComponent("\(safe).mp4")
            let url = try await ClipExport.export(item, to: destination, maxBytes: maxBytes)
            let duration = try? await AVURLAsset(url: url).load(.duration).seconds
            var attachment = PendingAttachment(url: url)
            attachment.clip = ClipExport.upload(for: item, duration: duration)
            return attachment
        }
    }

    /// `--demo` asks Discord nothing: the share lands in the conversation as
    /// Discord would hand it back — the clip fields read into its attachment,
    /// the file itself local — so the clip player can be looked at.
    private func echoDemoShare(
        _ files: [PendingAttachment], comment: String, in channelID: ChannelID, replyingTo reference: MessageReference?
    ) {
        guard let me = currentUserID else { return }
        mutateBox(channelID) { box in
            let after = box.messages.last?.sentAt ?? .now
            let milliseconds = UInt64(max(after, .now).timeIntervalSince1970 * 1_000) - Snowflake<MessageTag>.epochMilliseconds
            let id = MessageID(rawValue: (milliseconds << 22) | UInt64(box.messages.count % 1_024))
            let attachments = files.enumerated().map { index, file in
                Attachment(
                    id: AttachmentID(rawValue: id.rawValue &+ UInt64(index) &+ 1),
                    filename: file.filename,
                    url: file.url.absoluteString,
                    proxyURL: file.url.absoluteString,
                    contentType: file.isVideo ? "video/mp4" : file.contentType?.preferredMIMEType,
                    size: file.size,
                    durationSeconds: file.clip?.durationSeconds,
                    clip: file.clip.map { upload in
                        AttachmentClip(
                            title: upload.title,
                            applicationID: upload.applicationID,
                            createdAt: upload.createdAt,
                            participants: upload.participantIDs.compactMap { users[UserID(rawValue: $0)] },
                            timeline: upload.timeline,
                            remoteID: upload.remoteID
                        )
                    }
                )
            }
            box.messages.append(Message(
                id: id, channelID: channelID, authorID: me, content: comment,
                kind: reference == nil ? .default : .reply,
                payload: MessagePayload(attachments: attachments, reference: reference)
            ))
        }
        messageContentRevision &+= 1
    }
}
