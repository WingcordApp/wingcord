import Foundation
import Observation
import WingcordCore

/// Every server's Server Hub this session has asked about, and the edit in
/// progress (docs/BETA2.md, phase 9).
///
/// **Its own store, beside the model rather than inside it**, as the Members
/// page's is: the hub's state is a dozen fields only this page reads, and a
/// change to any of them should not invalidate whatever else reads the model.
@MainActor
@Observable
final class ServerHubStore {
    /// Each server's hub, as Discord answered it.
    var spaces: [GuildID: GuildSpace] = [:]
    /// Servers Discord answered 404 for: no hub yet.
    var missing: Set<GuildID> = []
    var loading: Set<GuildID> = []
    var failed: Set<GuildID> = []
    /// Of `failed`, the ones the network failed (no answer at all), the only
    /// case the page tells the reader to check their connection.
    var offline: Set<GuildID> = []
    /// What each widget shows, by widget id.
    var hydrations: [String: ServerHubHydrationState] = [:]
    /// The widgets each server can add, once Add Widget has asked.
    var catalogs: [GuildID: [GuildSpaceCatalogEntry]] = [:]
    /// The edit in progress — one at a time, for the server on screen.
    var draft: ServerHubDraft?
    /// The sheet over the page. One at a time (HIG: "Display only one sheet at
    /// a time from the main interface").
    var sheet: ServerHubSheet?
    /// The leaderboard open full size, by widget id: a layer of its own under
    /// the profiles (`ServerHubLeaderboardPresenter`), so a profile opened
    /// from one of its rows comes up on top (decision 22).
    var expandedLeaderboard: String?
    /// Servers whose publish or switch is on its way to Discord.
    var settingsInFlight: Set<GuildID> = []
    /// A whiteboard starting, so its button can say so.
    var launchingWhiteboard: GuildID?

    /// `--demo`'s pictures, drawn on this Mac where a real hub's are on
    /// Discord's CDN: the banner, and Image + Text pictures by widget id.
    @ObservationIgnored var demoBannerURL: URL?
    @ObservationIgnored var demoImageURLs: [String: URL] = [:]

    /// Whether Discord has answered for this server either way.
    func hasAnswer(for guildID: GuildID) -> Bool {
        spaces[guildID] != nil || missing.contains(guildID)
    }

    /// Forgets one server's hub, so the next visit asks again.
    func forget(_ guildID: GuildID) {
        if let space = spaces.removeValue(forKey: guildID) {
            for widget in space.widgets { hydrations[widget.id] = nil }
        }
        missing.remove(guildID)
        failed.remove(guildID)
        offline.remove(guildID)
    }
}
