import Foundation
import WingcordCore
import WingcordNet

// MARK: - Game detection, and the presence it publishes

extension SessionController {

    /// Starts watching for a running game, and republishes whenever one comes
    /// or goes.
    ///
    /// **The detector runs whether or not sharing is on.** Registered Games has
    /// to show the reader what is running before they decide to share it, and
    /// the gate that decides what reaches the wire lives in
    /// `AppModel.publishedActivities`. Watching costs two `NSWorkspace`
    /// notifications and nothing at rest.
    func startGameDetection() {
        games.onChange = { [weak self] in
            guard let self else { return }
            let detected = games.runningGame
            guard model.detectedGame != detected else { return }
            model.detectedGame = detected
            if let detected {
                Self.trace(
                    "game: \(detected.name)"
                        + (detected.isTranslated ? " (translated)" : "")
                        + (detected.isLauncher ? " (launcher)" : "")
                )
            } else {
                Self.trace("game: none")
            }
            // Mirrored locally for the same reason an embedded activity is: the
            // presence this client publishes never comes back, so a reader
            // looking at their own card would see nothing.
            model.reflectOwnPresenceNow()
            publishPresence()
            // The overlay comes up with the game, and the clip buffer arms with
            // it. Both are idempotent.
            model.refreshOverlay()
        }
        games.start()
    }

    /// Stops watching, and retires the presence.
    ///
    /// Called from `teardownConnection`, so signing out does not leave the
    /// previous account's game on the next one's roster.
    func stopGameDetection() {
        games.onChange = nil
        games.stop()
        guard model.detectedGame != nil else { return }
        model.detectedGame = nil
        model.reflectOwnPresenceNow()
        model.refreshOverlay()
    }

    // MARK: Activity privacy, written back

    /// Sends one privacy change, fetching the bytes it must preserve first.
    ///
    /// **The splice needs the message it is splicing into.** Writing without it
    /// replaces the account's whole privacy section with the one field this
    /// client changed — which would silently drop their restricted servers,
    /// their friend-source flags and their message-request settings. So when
    /// READY did not carry the raw bytes, they are fetched before anything is
    /// written, and a fetch that fails means nothing is written at all.
    func writeActivityPrivacy(
        _ change: ActivityPrivacyProto.Change,
        restoring previous: ActivityPrivacy
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await activityPrivacyBytes()
                try await rest.setActivityPrivacy(change, preserving: raw.privacy)
                model.activityPrivacyRaw = raw.privacy
                model.activityStatusRaw = raw.status
            } catch {
                Self.trace("activity privacy write failed: \(Self.describe(error))")
                model.activityPrivacy = previous
            }
        }
    }

    func writeSharesCurrentGame(_ shares: Bool, restoring previous: ActivityPrivacy) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await activityPrivacyBytes()
                try await rest.setSharesCurrentGame(shares, preserving: raw.status)
                model.activityPrivacyRaw = raw.privacy
                model.activityStatusRaw = raw.status
                // The published presence changes with it: a reader who turned
                // sharing off has to stop appearing in a game *now*, not at the
                // next reconnect.
                model.reflectOwnPresenceNow()
                publishPresence()
            } catch {
                Self.trace("share-activity write failed: \(Self.describe(error))")
                model.activityPrivacy = previous
            }
        }
    }

    /// The raw sub-messages, from READY if they are there and from the route if
    /// they are not.
    private func activityPrivacyBytes() async throws -> (privacy: Data, status: Data?) {
        if let privacy = model.activityPrivacyRaw {
            return (privacy, model.activityStatusRaw)
        }
        let fetched = try await rest.activityPrivacySettings()
        model.activityPrivacy = fetched.privacy
        return (fetched.raw ?? Data(), fetched.statusRaw)
    }

    /// Re-publishes after the sharing preference changes.
    ///
    /// **Both directions matter.** Turning it off has to send the array
    /// *without* the game — a client that only published on the way on would
    /// leave everybody's roster showing a game the reader has just asked it to
    /// hide, and that is the worst shape a privacy setting can fail in.
    func gameSharingPreferenceChanged() {
        guard model.currentUserID != nil else { return }
        model.reflectOwnPresenceNow()
        publishPresence()
    }
}
