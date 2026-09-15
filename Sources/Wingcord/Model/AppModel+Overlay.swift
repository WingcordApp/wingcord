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
        case .restrictedGuildIDs(let ids): activityPrivacy.restrictedGuildIDs = ids
        }
        sessionController.writeActivityPrivacy(change, restoring: previous)
    }

    /// "Share my activity", which lives on `status` rather than `privacy`.
    func setSharesCurrentGame(_ shares: Bool) {
        let previous = activityPrivacy
        activityPrivacy.sharesCurrentGame = shares
        sessionController.writeSharesCurrentGame(shares, restoring: previous)
    }
}
