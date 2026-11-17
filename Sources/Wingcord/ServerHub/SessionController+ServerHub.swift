import Foundation
import WingcordCore
import WingcordNet

// MARK: - Server Hub: the routes, and what their answers do
//
// docs/BETA2.md, phase 9. Discord's order (`121277`'s page): the space, then
// the widgets that need it hydrated, then — for an editor — the catalog.

extension SessionController {

    /// Asks Discord for a server's hub, once per session unless forced.
    func loadServerHub(_ guildID: GuildID, force: Bool = false) {
        let store = model.serverHub
        guard force || !store.hasAnswer(for: guildID), store.loading.insert(guildID).inserted else { return }
        guard !LaunchOptions.current.usesDemoFixtures else {
            // The demo's hub is seeded at launch; there is nothing to ask.
            store.loading.remove(guildID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            defer { store.loading.remove(guildID) }
            do {
                if let space = try await rest.guildSpace(guildID) {
                    store.spaces[guildID] = space
                    store.missing.remove(guildID)
                    store.failed.remove(guildID)
                    hydrateServerHub(guildID)
                } else {
                    store.spaces[guildID] = nil
                    store.missing.insert(guildID)
                }
                // The channel list's row waits on this answer (`offersServerHub`).
                model.sidebarRevision &+= 1
            } catch {
                store.failed.insert(guildID)
                if case DiscordREST.Failure.transport = error {
                    store.offline.insert(guildID)
                } else {
                    store.offline.remove(guildID)
                }
                Self.trace("server hub \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// What the widgets that need it show.
    ///
    /// **Three tries a widget, as Discord's own store** (`GuildSpaceHydrationStore`):
    /// a widget the answer left out, or a request that failed, is asked again
    /// after one second, then two; after the third it shows its failure.
    func hydrateServerHub(_ guildID: GuildID, attempt: Int = 0) {
        let store = model.serverHub
        guard let space = store.spaces[guildID] else { return }
        let wanted = space.widgets
            .filter { $0.requiresHydration && $0.kind.isDrawn && !$0.isLocked }
            .map(\.id)
            .filter { id in
                switch store.hydrations[id] {
                case .loaded, .loading: false
                case .failed, nil: attempt > 0 || store.hydrations[id] == nil
                }
            }
        guard !wanted.isEmpty else { return }
        for id in wanted { store.hydrations[id] = .loading }
        Task { [weak self] in
            guard let self else { return }
            var unanswered = wanted
            do {
                let answers = try await rest.hydrateGuildSpaceWidgets(guildID, widgetIDs: wanted)
                for (id, data) in answers where wanted.contains(id) {
                    store.hydrations[id] = .loaded(data)
                    // **The leaderboard's day, as Discord sent it**, so the
                    // podium's rule can be checked against a real board: its
                    // spelling decided whether the podium rose (2026-11-17).
                    if case .leaderboard(let board) = data {
                        Self.trace(
                            "server hub leaderboard: day_pt=\(board.dayPT ?? "nil") "
                                + "week_start=\(Int(board.weekStart.timeIntervalSince1970)) "
                                + "entries=\(board.entries.count) podium=\(board.isFinalDay)"
                        )
                    }
                }
                unanswered = wanted.filter { answers[$0] == nil }
                await resolveServerHubPeople(answers.values, in: guildID)
            } catch {
                Self.trace("server hub widgets \(guildID) failed: \(Self.describe(error))")
            }
            guard !unanswered.isEmpty else { return }
            guard attempt < 2 else {
                for id in unanswered { store.hydrations[id] = .failed }
                return
            }
            for id in unanswered { store.hydrations[id] = nil }
            try? await Task.sleep(for: .seconds(1 << attempt))
            hydrateServerHub(guildID, attempt: attempt + 1)
        }
    }

    /// The people and games the widgets name, so their rows have faces, names
    /// and box art — Discord's `k6` and `x`.
    func resolveServerHubPeople(_ answers: some Sequence<GuildSpaceHydration>, in guildID: GuildID) async {
        var people: [UserID] = []
        var gameIDs: [ApplicationID] = []
        for answer in answers {
            switch answer {
            case .leaderboard(let board):
                for entry in board.entries.prefix(21) {
                    people.append(entry.userID)
                    gameIDs += entry.applicationIDs.prefix(3)
                }
            case .popularGames(let games):
                people += games.userIDs.prefix(4)
                gameIDs += games.games.prefix(ServerHubMetrics.maxGameTiles).map(\.applicationID)
            case .popularMusic(let music):
                people += music.listeners.prefix(10).map(\.userID)
            case .other:
                break
            }
        }
        requestServerHubMembers(people, in: guildID)
        // **Applications first, then their games** — Discord's `eh`: the
        // widgets name *application* ids; the application gives the name and
        // the icon, and its canonical game (itself for a game, else the game
        // it links) gives the box art. Asking `/games` with the application
        // ids alone left every game whose id differs as "Unknown game" with
        // an empty icon (Alex's leaderboard, 2026-11-16).
        let applications = Array(Set(gameIDs))
        guard !applications.isEmpty else { return }
        await loadWidgetApplications(ids: applications)
        let canonical = Set(applications.map { model.canonicalGameID(for: $0) }).filter { model.games[$0] == nil }
        if !canonical.isEmpty { await loadGames(ids: Array(canonical)) }
    }

    /// Asks the gateway about people the hub names whom this client doesn't
    /// know as members — once per person per session, as `resolveMessageMembers`.
    func requestServerHubMembers(_ userIDs: [UserID], in guildID: GuildID) {
        guard let socket else { return }
        let known = model.members[guildID]
        let wanted = Array(Set(userIDs)).filter { userID in
            known?[userID] == nil
                && memberRequests.insert(MemberRequest(guildID: guildID, userID: userID)).inserted
        }
        guard !wanted.isEmpty else { return }
        Task { await socket.requestGuildMembers(guildID: guildID, userIDs: wanted) }
    }

    /// The widgets this server can add, once.
    func loadServerHubCatalog(_ guildID: GuildID) {
        let store = model.serverHub
        guard store.catalogs[guildID] == nil else { return }
        guard !LaunchOptions.current.usesDemoFixtures else {
            store.catalogs[guildID] = DemoFixtures.serverHubCatalog
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                store.catalogs[guildID] = try await rest.guildSpaceCatalog(guildID)
            } catch {
                Self.trace("server hub catalog \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Sends the edit whole — Discord's `Fj`. The page leaves edit mode on the
    /// answer, and every widget is hydrated afresh.
    func saveServerHub() {
        let store = model.serverHub
        guard var draft = store.draft, !draft.isSaving else { return }
        // Discord refuses an Image + Text with neither words nor a picture; say
        // so here, beside the button, rather than after the round trip.
        if draft.widgets.contains(where: { $0.kind == .imageText && !$0.config.hasContent }) {
            draft.saveState = .failed("An Image + Text widget needs some text or an image.")
            store.draft = draft
            return
        }
        draft.saveState = .saving
        store.draft = draft
        let guildID = draft.guildID
        let banner: GuildSpaceBannerChange? = switch draft.banner {
        case .unchanged: nil
        case .replaced(let dataURL, _): .set(dataURL)
        case .removed: .remove
        }

        guard !LaunchOptions.current.usesDemoFixtures else {
            DemoFixtures.saveServerHub(draft, model: model)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await rest.saveGuildSpace(guildID, banner: banner, widgets: draft.widgets)
                for widget in (store.spaces[guildID]?.widgets ?? []) + saved.widgets {
                    store.hydrations[widget.id] = nil
                }
                store.spaces[guildID] = saved
                store.missing.remove(guildID)
                store.draft = nil
                store.sheet = nil
                hydrateServerHub(guildID)
            } catch {
                store.draft?.saveState = .failed(Self.reason(for: error, verb: "save the Server Hub"))
            }
        }
    }

    /// Publishes a draft hub so everyone in the server sees it.
    func publishServerHub(_ guildID: GuildID) {
        updateServerHubSettings(guildID, publishStatus: .published)
    }

    /// Switches the hub on or off — Server Settings › Engagement.
    func setServerHubEnabled(_ guildID: GuildID, isOn: Bool) {
        updateServerHubSettings(guildID, isEnabled: isOn)
    }

    private func updateServerHubSettings(
        _ guildID: GuildID,
        isEnabled: Bool? = nil,
        publishStatus: GuildSpaceSettings.PublishStatus? = nil
    ) {
        let store = model.serverHub
        guard store.settingsInFlight.insert(guildID).inserted else { return }
        guard !LaunchOptions.current.usesDemoFixtures else {
            var settings = model.guilds[guildID]?.spaceSettings ?? GuildSpaceSettings(isEnabled: true, publishStatus: .draft)
            if let isEnabled { settings.isEnabled = isEnabled }
            if let publishStatus { settings.publishStatus = publishStatus }
            model.guilds[guildID]?.spaceSettings = settings
            model.sidebarRevision &+= 1
            store.settingsInFlight.remove(guildID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            defer { store.settingsInFlight.remove(guildID) }
            do {
                let settings = try await rest.updateGuildSpaceSettings(
                    guildID, isEnabled: isEnabled, publishStatus: publishStatus
                )
                model.guilds[guildID]?.spaceSettings = settings
                model.sidebarRevision &+= 1
            } catch {
                model.reportActionFailure(Self.reason(for: error, verb: "change the Server Hub"))
            }
        }
    }

    /// Starts the whiteboard in the hub's channel, or joins it there.
    ///
    /// **Discord's launch, into a different kind of channel** (`795816`'s `su`):
    /// the hub's channel is one of the kinds an activity can start in, and the
    /// start is the app's entry-point command, as in a text channel. So this is
    /// `launchActivity` with the whiteboard's id and the hub's channel.
    func launchWhiteboard(in guildID: GuildID) async {
        let store = model.serverHub
        guard let channelID = store.spaces[guildID]?.channelID, store.launchingWhiteboard == nil else { return }
        store.launchingWhiteboard = guildID
        defer { store.launchingWhiteboard = nil }
        let appID = AppModel.whiteboardApplicationID
        if model.activityApp(appID) == nil { await loadActivityApp(appID) }
        guard let app = model.activityApp(appID) else {
            model.reportActionFailure("The whiteboard isn\u{2019}t available right now.")
            return
        }
        // Discord's `im()`: join the board running in the hub's channel,
        // launch one only where none is (decision 6).
        await startActivity(app, in: channelID, section: "guild_space", guildID: guildID)
    }

    /// Who may draw: Use Activities denied to @everyone in the hub's channel and
    /// allowed to the chosen roles; or, with none chosen, nobody singled out —
    /// Discord's whiteboard settings.
    func setWhiteboardRoles(_ roleIDs: Set<RoleID>, in guildID: GuildID) {
        guard let channelID = model.serverHub.spaces[guildID]?.channelID,
              let channel = model.channelIndex[channelID]
        else { return }
        let everyoneID = guildID.rawValue
        var overwrites = channel.overwrites.filter { overwrite in
            // Every role's grant of the permission is rewritten below.
            overwrite.subject != .role
                || (overwrite.id != everyoneID && !overwrite.allow.contains(.useEmbeddedActivities))
        }
        var everyone = channel.overwrites.first { $0.subject == .role && $0.id == everyoneID }
            ?? PermissionOverwrite(id: everyoneID, subject: .role, allow: [], deny: [])
        if roleIDs.isEmpty {
            everyone.deny.remove(.useEmbeddedActivities)
        } else {
            everyone.deny.insert(.useEmbeddedActivities)
            for roleID in roleIDs {
                var grant = channel.overwrites.first { $0.subject == .role && $0.id == roleID.rawValue }
                    ?? PermissionOverwrite(id: roleID.rawValue, subject: .role, allow: [], deny: [])
                grant.allow.insert(.useEmbeddedActivities)
                grant.deny.remove(.useEmbeddedActivities)
                overwrites.append(grant)
            }
        }
        overwrites.append(everyone)
        guard !LaunchOptions.current.usesDemoFixtures else {
            var updated = channel
            updated.overwrites = overwrites
            model.channelIndex.upsert(updated)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                if let updated = try await rest.setChannelOverwrites(overwrites, of: channelID) {
                    model.channelIndex.upsert(updated)
                }
            } catch {
                model.reportActionFailure(Self.reason(for: error, verb: "change who can use the whiteboard"))
            }
        }
    }
}
