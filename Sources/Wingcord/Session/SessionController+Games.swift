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
        registerManualGames()
        games.onChange = { [weak self] in
            self?.applyRunningGame()
        }
        games.start()
    }

    /// Hands the detector the games added by hand.
    ///
    /// **It was never done.** They were saved, and only registered with the
    /// detector at the moment they were added — so after a relaunch a game
    /// added by hand was not detected at all. Ids from builds that derived
    /// them from `hashValue` (seeded afresh each launch) are re-keyed to the
    /// stable one on the way.
    private func registerManualGames() {
        let settings = AppSettings.shared
        for entry in settings.manualGames
        where entry.id != RegisteredGamesStore.manualID(forExecutableAt: entry.path) {
            settings.addManualGame(
                name: entry.name, path: entry.path,
                id: ApplicationID(rawValue: RegisteredGamesStore.manualID(forExecutableAt: entry.path))
            )
        }
        for entry in settings.manualGames {
            games.addManualGame(
                GameDetector.DetectedGameOverride(id: ApplicationID(rawValue: entry.id), name: entry.name),
                forExecutableAt: entry.path
            )
        }
        RegisteredGamesStore.shared.adopt(settings.manualGames)
    }

    /// Publishes what is running — unless the reader switched its detection
    /// off in Registered Games, in which case nothing is.
    ///
    /// Called by the detector when the running game changes and by
    /// Registered Games when a switch on it does.
    func applyRunningGame() {
        let running = games.runningGame
        let store = RegisteredGamesStore.shared
        // "Last played" moves when a game starts and again when it stops.
        if let running { store.noteRunning(running) }
        if let previous = model.detectedGame, previous.id != running?.id { store.noteRunning(previous) }
        let detected = running.flatMap { store.games.isDetected($0.id.rawValue) ? $0 : nil }
        guard model.detectedGame != detected else {
            // A switch on the game that is up — the overlay or clips — still
            // has to reach the overlay and the buffer.
            model.refreshOverlay()
            return
        }
        model.detectedGame = detected
        if let detected {
            Self.trace(
                "game: \(detected.name)"
                    + (detected.isTranslated ? " (translated)" : "")
                    + (detected.isLauncher ? " (launcher)" : "")
            )
        } else {
            Self.trace(running == nil ? "game: none" : "game: \(running!.name) (detection off)")
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
        // Now Playing rides this switch: its reader stops with it at once.
        nowPlaying.refresh()
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
                nowPlaying.refresh()
            }
        }
    }

    /// Saves the reader's custom status into the settings blob.
    ///
    /// **Optimistic, and put back on a refusal** — the model has already moved
    /// and published it, which is what makes the bubble change under the
    /// pointer. A write that fails silently would leave a status everybody else
    /// can see and this client would forget on its next launch.
    func writeCustomStatus(_ status: CustomStatus?, restoring previous: CustomStatus?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await activityPrivacyBytes()
                try await rest.setCustomStatus(status, preserving: raw.status)
                model.activityPrivacyRaw = raw.privacy
                model.activityStatusRaw = raw.status
            } catch {
                Self.trace("custom status write failed: \(Self.describe(error))")
                model.selfCustomStatus = previous
                publishPresence()
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
        // Now Playing rides the same switch, and its reader stops with it.
        nowPlaying.refresh()
        model.reflectOwnPresenceNow()
        publishPresence()
    }
}
