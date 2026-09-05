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
        guard let activity = model.presences[userID]?.primaryActivity else { return }
        loadActivityButtons(of: userID, activity: activity)
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
