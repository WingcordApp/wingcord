import Foundation
import WingcordCore
import WingcordNet

extension SessionController {

    /// The Activity tab's two fetches, started when a profile opens.
    ///
    /// **Started with the profile, not from the tab.** The tab only exists
    /// because there is something behind it, so a `.task` on the tab would mean
    /// the list begins loading after somebody has already asked to read it — and
    /// the picker's own gating has to know whether the list is empty before it
    /// can decide to draw the tab at all.
    ///
    /// The button URLs are the second fetch and they are **conditional on there
    /// being buttons**: an activity that published none has no metadata to ask
    /// for, and asking anyway is one round trip per profile opened for a 204.
    func loadActivityDetail(of userID: UserID) {
        loadRecentActivity(of: userID)
        guard let presence = model.presences[userID], let activity = presence.primaryActivity else { return }
        loadActivityButtons(of: userID, activity: activity)
        loadActivityGames(presence.activities?.list ?? [activity])
    }

    /// The game record behind what somebody is playing right now.
    ///
    /// **Asked for explicitly, rather than left to the recent-activity list.**
    /// The store button under the activity reads `Game.storeOffers`, and the
    /// only other thing that fills `model.games` for a profile is the content
    /// inventory — which answers **403** for anybody who has switched Recent
    /// Activity off, and is filed as an empty list when it does. Leaning on it
    /// would mean the button appearing for some people and not others for a
    /// reason nothing on screen could explain.
    ///
    /// `/games` answers for titles Discord tracks as games and says nothing
    /// about an editor, a bot or Spotify. `loadGames` remembers what it asked
    /// for, so each of those costs one request for the life of the session
    /// rather than one per profile opened.
    ///
    /// **Every game being played, not only the first**: the record is also what
    /// decides whether an activity's card opens a game profile at all — see
    /// `AppModel.gameProfileOpener` — and the full profile draws every one.
    private func loadActivityGames(_ activities: [Activity]) {
        let ids = activities.compactMap { $0.kind == .playing ? $0.applicationID : nil }
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await loadGames(ids: ids)
            // **The hop Discord makes for a console title** — see
            // `AppModel.canonicalGameID`. An application `/games` did not
            // answer for may name its game in `linked_games`; its record says
            // so, and the game it names is then asked for like any other. An
            // editor or a bot has a record with no game in it, which is kept,
            // so each costs one request for the session and not one a profile.
            let unanswered = ids.filter { model.games[$0] == nil }
            guard !unanswered.isEmpty else { return }
            await loadWidgetApplications(ids: unanswered)
            await loadGames(ids: unanswered.compactMap { model.widgetApplications[$0]?.primaryGameID })
        }
    }

    /// Resolves the marks for the games people in voice channels are playing.
    ///
    /// **Resolved where the data lands, never from the projection that draws
    /// it.** A fetch started inside a computed property runs during a body
    /// evaluation, which is a state write in the middle of a view update — the
    /// same rule the recent-activity list is held to below.
    ///
    /// Scoped to the server on screen. A busy account has people in voice
    /// channels in ninety servers and the sidebar draws one of them; resolving
    /// the rest would be a batch request for icons nothing is going to ask for.
    /// `resolveApplications` filters what it already knows, so a repeat costs a
    /// set subtraction and no request.
    func refreshVoiceActivityIcons() {
        guard let guildID = model.selectedGuildID else { return }
        var wanted: [ApplicationID] = []
        for state in model.voiceStates.values where state.guildID == guildID {
            guard let activity = model.presences[state.userID]?.primaryActivity,
                  let applicationID = activity.applicationID,
                  model.games[applicationID] == nil
            else { continue }
            wanted.append(applicationID)
        }
        guard !wanted.isEmpty else { return }
        model.resolveApplications(wanted)
    }

    /// Somebody's recent activity.
    ///
    /// **Cached for the session and never refreshed.** An inventory entry is a
    /// record of something that already happened; the only one that can change
    /// while a profile is open is the live one at the top, and that is what the
    /// presence already says.
    func loadRecentActivity(of userID: UserID) {
        guard model.recentActivity[userID] == nil,
              recentActivityFetches.insert(userID).inserted
        else { return }
        model.recentActivityLoading.insert(userID)
        Task { [weak self] in
            guard let self else { return }
            defer {
                recentActivityFetches.remove(userID)
                model.recentActivityLoading.remove(userID)
            }
            do {
                let entries = try await rest.recentActivity(of: userID)
                model.recentActivity[userID] = entries
                // Every game row opens a game profile, and a row cannot draw its
                // own box art without the game. Batched through the same table
                // the board fills, so a rotation game already on the board costs
                // nothing here.
                let gameIDs = entries.compactMap { entry -> ApplicationID? in
                    guard case .game(_, let id) = entry.subject else { return nil }
                    return id
                }
                if !gameIDs.isEmpty { await loadGames(ids: gameIDs) }

                // **And the applications `/games` will not answer for.** An
                // activity that is not a tracked game — Wordle, a bot's own
                // presence — has no box art at all, and its application icon
                // is the picture Discord draws in the row. Resolved *here*,
                // where the list lands, rather than from the projection that
                // reads it: a fetch kicked off inside a computed property runs
                // during a body evaluation, which is a state write in the
                // middle of a view update.
                let unresolved = entries.compactMap { entry -> ApplicationID? in
                    guard let id = entry.subject.applicationID,
                          model.games[id] == nil
                    else { return nil }
                    return id
                }
                if !unresolved.isEmpty { model.resolveApplications(unresolved) }
            } catch {
                // **An empty list, not an absent one.** Left absent, the tab's
                // gating would ask again every time the profile opened — and
                // this route answers 403 for an account that has switched
                // Recent Activity off, which is a permanent answer.
                model.recentActivity[userID] = []
                Self.trace("recent activity \(userID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Where an activity's custom buttons go.
    ///
    /// **Both halves of the address come off the activity itself** — its
    /// `session_id` and its `application_id` — and an activity missing either
    /// cannot be asked about. That is not a defensive guard: `session_id` is
    /// nullable on the wire and most activities carry no buttons at all, so the
    /// common case is that this returns without a request.
    func loadActivityButtons(of userID: UserID, activity: Activity) {
        guard !activity.buttons.isEmpty,
              let session = activity.sessionID,
              let application = activity.applicationID,
              model.activityButtonURLs[session] == nil,
              activityMetadataFetches.insert(session).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { activityMetadataFetches.remove(session) }
            do {
                let metadata = try await rest.activityMetadata(
                    of: userID,
                    session: session,
                    application: application
                )
                model.activityButtonURLs[session] = metadata.buttonURLs
            } catch {
                // Filed as empty so the buttons stay undrawn rather than the
                // fetch being retried on every hover. A label with no address
                // is the inert control `INVARIANTS.md` §5.5 forbids.
                model.activityButtonURLs[session] = []
                Self.trace("activity metadata \(session) failed: \(Self.describe(error))")
            }
        }
    }
}

// MARK: - Stream previews

extension SessionController {

    /// Fetches the address of a stream's newest thumbnail.
    ///
    /// **One request in flight per stream, and the answer replaces the last
    /// one.** The caller is a hover that repeats every few seconds, so without
    /// the in-flight guard a slow answer would stack requests behind a pointer
    /// that has not moved.
    func loadStreamPreview(key: String) {
        guard streamPreviewFetches.insert(key).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { streamPreviewFetches.remove(key) }
            do {
                guard let url = try await rest.streamPreview(key: key) else { return }
                model.streamPreviews[key] = url
            } catch {
                // A stream that ended answers 404, which is an answer rather
                // than a fault. The flyout draws its plate either way.
                Self.trace("stream preview \(key) failed: \(Self.describe(error))")
            }
        }
    }
}
