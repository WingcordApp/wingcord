import AppKit
import Foundation
import WingcordCore
import WingcordNet

// MARK: - The overlay and clips, from the model's side
//
// The model owns the controller and the recorder because the keybinds reach
// them from outside any view, and because the detected game — which arms both —
// already lives here.

extension AppModel {

    // MARK: Arming

    /// Brings the overlay and the clip buffer into step with what is running.
    ///
    /// Called whenever the detected game changes or a preference that gates
    /// either one does. Idempotent on both sides.
    func refreshOverlay() {
        overlay.attach(model: self)
        overlay.refreshPresentation()

        let wantsClips = AppSettings.shared.clipsEnabled && detectedGame != nil
        let pid = wantsClips ? detectedGame?.processIdentifier : nil
        Task { await clipRecorder.arm(processIdentifier: pid) }
    }

    // MARK: The clip keys

    /// Writes the last few seconds out.
    ///
    /// **Every failure says what to do about it.** The clip key is pressed in
    /// the middle of something worth keeping; "it didn't work" with no reason
    /// is the worst possible answer, and all four reasons here are actionable.
    func saveClip() {
        guard AppSettings.shared.clipsEnabled else {
            overlay.showClipFeedback(
                .failed("Clips is off. Turn it on in Settings › Clips.")
            )
            return
        }
        let length = AppSettings.shared.clipLength.seconds
        let folder = ClipLibrary.folder
        let name = ClipLibrary.name(for: detectedGame?.name)
        overlay.showClipFeedback(.working())
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await clipRecorder.save(seconds: length, to: folder, named: name)
                overlay.showClipFeedback(.saved(url.deletingPathExtension().lastPathComponent))
                clipsRevision &+= 1
            } catch {
                overlay.showClipFeedback(.failed(Self.clipFailureText(error)))
            }
        }
    }

    /// Writes the frame that is on screen.
    func saveScreenshot() {
        let folder = ClipLibrary.folder
        let name = ClipLibrary.name(for: detectedGame?.name)
        let pid = detectedGame?.processIdentifier
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await ClipRecorder.screenshot(
                    processIdentifier: pid, to: folder, named: name
                )
                overlay.showClipFeedback(
                    .screenshot(url.deletingPathExtension().lastPathComponent)
                )
                clipsRevision &+= 1
            } catch {
                overlay.showClipFeedback(.failed(Self.clipFailureText(error)))
            }
        }
    }

    private static func clipFailureText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Could not save that one."
    }

    // MARK: Notifications over the game

    /// Opens a conversation as a chat window on the overlay.
    func openOverlayChat(_ channelID: ChannelID) {
        guard canOpen(channelID) else { return }
        overlay.openChat(channelID)
    }

    /// The same, for somebody the reader may not have written to yet.
    ///
    /// **The conversation is created rather than the row being inert.** It is
    /// `POST /users/@me/channels`, it is idempotent, and the profile's Message
    /// control has been going through it since the profile rebuild — a friends
    /// list that only opened conversations which already existed would leave
    /// most rows doing nothing, which is §5.5's inert control with a friendly
    /// face on it.
    func openOverlayChat(with userID: UserID) {
        guard userID != currentUserID else { return }
        if let existing = directMessageChannel(with: userID) {
            overlay.openChat(existing)
            return
        }
        sessionController.openConversation(with: userID, to: .overlay)
    }

    /// Joins a room the sidebar offered.
    ///
    /// **Two entry points, because a guild room and a direct call are two
    /// different acts.** `joinVoice` is gated on `CONNECT`, which a direct call
    /// has no bit for; `joinCall` rings nobody, which is what joining a call
    /// already in progress has to do — a ring there is a phone going off in the
    /// ear of somebody already on it.
    func joinOverlayRoom(_ channelID: ChannelID) {
        guard connectedVoiceChannelID != channelID else { return }
        if channelIndex[channelID]?.guildID != nil {
            joinVoice(channelID)
        } else {
            joinCall(in: channelID)
        }
    }

    /// Answers a toast, in the conversation it came from.
    ///
    /// **A reply to the message, not a line in the channel.** The toast names
    /// one message and the reader is answering that one; sending it unanchored
    /// would drop the only piece of context a person mid-game has.
    ///
    /// It also acknowledges: somebody who has just answered a message has
    /// plainly read it, and leaving it bold would mean coming back to a badge
    /// for a conversation they already dealt with.
    func replyFromOverlay(_ text: String, to notice: OverlayNotice) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // **Held inside a slowmode wait, and the toast stays up with the reply
        // still in its field** — there is no composer to put it back in.
        // Dismissing is what clears the field, so a reply that goes cannot be
        // posted twice by a second Return.
        guard !trimmed.isEmpty, !holdsForSlowmode(notice.channelID) else { return }
        sessionController.send(trimmed, in: notice.channelID, replyingTo: notice.messageID)
        sessionController.acknowledge(notice.messageID, in: notice.channelID)
        overlay.dismiss(notice)
    }

    /// Shows a message on the overlay instead of in Notification Center.
    ///
    /// **One or the other, never both.** A system banner behind a full-screen
    /// game is a banner nobody sees, and a reader who got both would be told
    /// twice about one message. The overlay wins whenever it is up.
    func announceOverOverlay(_ notice: OverlayNotice) -> Bool {
        guard overlay.isPresented, AppSettings.shared.overlayShowsNotifications else {
            return false
        }
        overlay.show(notice)
        return true
    }
}

// MARK: - Activity privacy, written back

extension AppModel {

    /// Applies a privacy change locally and sends it.
    ///
    /// **Optimistic, and restored on failure.** Every one of these is a toggle
    /// or a radio the reader is looking at; waiting a round trip to move it
    /// reads as a control that does not work, and leaving it moved after a
    /// failure is a client that lies about a privacy setting.
    func applyActivityPrivacy(_ change: ActivityPrivacyProto.Change) {
        let previous = activityPrivacy
        switch change {
        case .friendsJoin(let allowed): activityPrivacy.allowsFriendsToJoin = allowed
        case .voiceJoin(let allowed): activityPrivacy.allowsVoiceParticipantsToJoin = allowed
        case .sharingScope(let scope): activityPrivacy.sharingScope = scope
        case .activityRestrictedGuildIDs(let ids): activityPrivacy.activityRestrictedGuildIDs = ids
        case .guildList(let toggle, let ids): activityPrivacy.setGuildIDs(ids, for: toggle)
        }
        sessionController.writeActivityPrivacy(change, restoring: previous)
    }

    /// One switch on a server's own Privacy Settings sheet.
    ///
    /// **The switch's polarity is the inverse of the list's.** Every one of
    /// these fields is a *restriction* list, so turning a switch ON removes the
    /// server and turning it OFF adds it — see `GuildPrivacy`.
    func setGuildPrivacy(_ toggle: GuildPrivacyToggle, on: Bool, in guildID: GuildID) {
        var ids = activityPrivacy.guildIDs(for: toggle)
        if on { ids.remove(guildID) } else { ids.insert(guildID) }
        applyActivityPrivacy(.guildList(toggle, ids))
    }

    /// "Share my activity", which lives on `status` rather than `privacy`.
    func setSharesCurrentGame(_ shares: Bool) {
        let previous = activityPrivacy
        activityPrivacy.sharesCurrentGame = shares
        sessionController.writeSharesCurrentGame(shares, restoring: previous)
    }
}
