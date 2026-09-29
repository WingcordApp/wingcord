import Foundation
import WingcordCore
import WingcordNet

extension SessionController {

    /// Fills in everything a board needs, once the profile route has said what
    /// is on it.
    ///
    /// **Called from `loadProfile`, not from the view.** The widgets arrive with
    /// the profile; starting from a `.task` on the Board tab would mean the
    /// board's fetches only begin when somebody clicks the tab, and the tab
    /// itself only exists because the widgets already arrived.
    ///
    /// Three fetches, and they are **concurrent** because they share no bucket:
    /// `/games`, `/application-identities` and `/applications/public` are three
    /// routes, and running them in sequence would stack three round trips in
    /// front of a card that is already on screen.
    func loadBoard(of userID: UserID, widgets: [ProfileWidget]) {
        guard !widgets.isEmpty else { return }

        let gameIDs = widgets.flatMap { $0.games.map(\.gameID) }
        let applicationIDs = widgets.compactMap(\.applicationID)

        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                if !gameIDs.isEmpty {
                    group.addTask { await self.loadGames(ids: gameIDs) }
                }
                if !applicationIDs.isEmpty {
                    group.addTask { await self.loadWidgetIdentities(of: userID) }
                    group.addTask {
                        await self.loadWidgetApplications(ids: applicationIDs)
                        // No strip without a game list, so no fetch for one.
                        if !gameIDs.isEmpty { await self.loadApplicationGames(applicationIDs) }
                    }
                    group.addTask { await self.loadWidgetConfigs(for: applicationIDs) }
                }
            }
        }
    }

    /// Games, into the shared table.
    ///
    /// **Only the ones nothing has already answered for.** A server of people
    /// who all play the same five games resolves them once for the session, and
    /// the second board opened asks for nothing at all.
    ///
    /// **And only the ones nothing has already ASKED about.** `/games` answers
    /// for titles Discord tracks as games and returns nothing at all for an
    /// application that is not one — Wordle, a bot, an editor, Spotify. Keyed
    /// on "is it in the table", every one of those is asked again every time
    /// anything names it, which is once per profile opened on somebody who
    /// spends their day in Visual Studio Code. The set is the answer's absence
    /// made storable, which is `INVARIANTS.md` §5.5's rule about a 404 being
    /// stored as an empty answer rather than left absent.
    ///
    /// Recorded on **success only**: a request that threw proves nothing about
    /// the ids in it, and latching them would turn one dropped connection into
    /// a session with no box art.
    func loadGames(ids: [ApplicationID]) async {
        let wanted = ids.filter { model.games[$0] == nil && !gameFetches.contains($0) }
        guard !wanted.isEmpty else { return }
        do {
            let games = try await rest.games(ids: wanted)
            gameFetches.formUnion(wanted)
            for game in games {
                model.games[game.id] = game
            }
        } catch {
            Self.trace("games failed: \(Self.describe(error))")
        }
    }

    /// The games application widgets are about. The popout's game strip
    /// counts an application widget's own game (module `657538`), and its mark
    /// is a `/games` answer like the rest.
    private func loadApplicationGames(_ applicationIDs: [ApplicationID]) async {
        await loadGames(ids: applicationIDs.compactMap { model.widgetApplications[$0]?.primaryGameID })
    }

    private func loadWidgetIdentities(of userID: UserID) async {
        do {
            model.applicationIdentities[userID] = try await rest.applicationIdentities(of: userID)
        } catch {
            Self.trace("application identities \(userID) failed: \(Self.describe(error))")
        }
    }

    private func loadWidgetApplications(ids: [ApplicationID]) async {
        let wanted = ids.filter { model.widgetApplications[$0] == nil }
        guard !wanted.isEmpty else { return }
        do {
            for application in try await rest.widgetApplications(ids: wanted) {
                model.widgetApplications[application.id] = application
            }
        } catch {
            Self.trace("widget applications failed: \(Self.describe(error))")
        }
    }

    /// The templates that say what a linked game's numbers are called.
    ///
    /// **The featured set first, and once per session.** It answers for every
    /// application Discord has promoted — which is every linked game — in one
    /// call, and it is why Discord's own client shows "Authority Level" the
    /// instant a profile opens rather than a beat later. Only an application it
    /// did not cover is then asked for individually, which is the case for a
    /// widget somebody authored for themselves.
    private func loadWidgetConfigs(for ids: [ApplicationID]) async {
        await loadFeaturedWidgetConfigs()
        for id in ids where model.widgetConfigs[id] == nil {
            guard widgetConfigFetches.insert(id).inserted else { continue }
            defer { widgetConfigFetches.remove(id) }
            do {
                // A draft is the author's unpublished working copy and is
                // visible to them alone; a board draws the published one.
                let configs = try await rest.widgetConfigs(for: id)
                if let config = configs.first(where: { $0.status == .published }) ?? configs.first {
                    model.widgetConfigs[id] = config
                }
            } catch {
                Self.trace("widget configs \(id) failed: \(Self.describe(error))")
            }
        }
    }

    private func loadFeaturedWidgetConfigs() async {
        guard !didLoadFeaturedWidgetConfigs else { return }
        didLoadFeaturedWidgetConfigs = true
        do {
            for config in try await rest.featuredWidgetConfigs() {
                // **First writer wins.** An application can publish several
                // configs and the featured map lists them all; the board draws
                // one, and rewriting the slot per entry would make which one
                // depend on a dictionary's iteration order.
                if model.widgetConfigs[config.applicationID] == nil {
                    model.widgetConfigs[config.applicationID] = config
                }
            }
        } catch {
            // Not latched back to false: a featured set that 404s or 403s for
            // this account will do so every time, and retrying it per profile
            // is one wasted request per card. The per-application route is the
            // standby and it is already in the loop above.
            Self.trace("featured widget configs failed: \(Self.describe(error))")
        }
    }

    // MARK: A game's own profile

    /// Everything the game profile draws that is not already resident.
    ///
    /// **Four fetches, and three of them are optional in the honest sense**: a
    /// game with no announcements channel, no Discord server or no similar-games
    /// entry answers empty, and the sections for those simply do not appear.
    /// The game itself is the only one the sheet cannot open without.
    func loadGameProfile(_ gameID: ApplicationID) {
        guard gameProfileFetches.insert(gameID).inserted else { return }
        model.gameProfilesLoading.insert(gameID)
        Task { [weak self] in
            guard let self else { return }
            defer {
                gameProfileFetches.remove(gameID)
                model.gameProfilesLoading.remove(gameID)
            }

            // The game first and alone: the community card's invite code is
            // read off *its* websites, so that fetch cannot be started beside
            // this one.
            if model.games[gameID] == nil {
                do {
                    if let game = try await rest.game(gameID) { model.games[gameID] = game }
                } catch {
                    Self.trace("game \(gameID) failed: \(Self.describe(error))")
                    closeGameProfile(gameID)
                    model.reportActionFailure("This game's profile could not be loaded.")
                    return
                }
            }
            // **No record is an answer**: not a game Discord keeps a profile
            // for. The entry points do not offer one (`gameProfileOpener`); a
            // page that got here anyway closes rather than spinning for ever.
            guard let game = model.games[gameID], !game.isProfileDisabled else {
                closeGameProfile(gameID)
                return
            }

            await withTaskGroup(of: Void.self) { group in
                if model.gameAnnouncements[gameID] == nil {
                    group.addTask { await self.loadGameAnnouncements(gameID) }
                }
                if model.similarGames[gameID] == nil {
                    group.addTask { await self.loadSimilarGames(gameID) }
                }
                if let code = game.communityInviteCode, model.gameCommunities[gameID] == nil {
                    group.addTask { await self.loadGameCommunity(gameID, code: code) }
                }
                // The application the Link Account card links through — any
                // game's, not only a widget game's.
                if let official = game.officialApplicationID {
                    group.addTask { await self.loadWidgetApplications(ids: [official]) }
                }
            }
        }
    }

    /// Takes the page away, if it is still this game's.
    private func closeGameProfile(_ gameID: ApplicationID) {
        guard model.gameProfileRequest?.gameID == gameID else { return }
        model.dismissGameProfile()
    }

    private func loadGameAnnouncements(_ gameID: ApplicationID) async {
        do {
            let announcements = try await rest.gameAnnouncements(gameID)
            // **The authors are merged, never assigned over.** These are
            // webhooks and bots the store may already hold a fuller record for,
            // and an announcement's author object is as thin as a roster row's.
            for (id, author) in announcements.authors where model.users[id] == nil {
                model.users[id] = author
            }
            model.gameAnnouncements[gameID] = announcements
        } catch {
            Self.trace("announcements \(gameID) failed: \(Self.describe(error))")
        }
    }

    private func loadSimilarGames(_ gameID: ApplicationID) async {
        do {
            let ids = try await rest.similarGames(to: gameID)
            model.similarGames[gameID] = ids
            // The row draws covers, so the games themselves are needed too —
            // batched through the same shared table the board fills.
            await loadGames(ids: ids)
        } catch {
            Self.trace("similar games \(gameID) failed: \(Self.describe(error))")
        }
    }

    private func loadGameCommunity(_ gameID: ApplicationID, code: String) async {
        do {
            model.gameCommunities[gameID] = try await rest.invitePreview(code: code)
        } catch {
            Self.trace("invite \(code) failed: \(Self.describe(error))")
        }
    }
}
