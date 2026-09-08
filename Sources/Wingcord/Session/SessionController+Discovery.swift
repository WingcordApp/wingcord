import Foundation
import WingcordCore
import WingcordNet

// Discovery's fetches.
//
// **Last-write-wins, and every answer is checked against its own question.**
// The page has three inputs that all move by hand — the tab, the category and
// the field — and any of them can change while a request is out. An answer that
// landed unchecked would fill the Gaming grid with the results of a search
// somebody had already moved past.

extension SessionController {

    /// Fills whichever half is showing, and the category lists behind both.
    ///
    /// - Parameter debounced: true from the field, which moves per keystroke.
    ///   The tab and the category are single clicks and go out immediately —
    ///   waiting on those is latency nobody asked for.
    func loadDiscovery(debounced: Bool = false) {
        guard let state = model.discovery else { return }
        discoveryTask?.cancel()
        loadDiscoveryCategories()

        switch state.tab {
        case .servers:
            model.discovery?.isLoading = true
            model.discovery?.failure = nil
        case .apps:
            model.discovery?.isLoadingApps = true
            model.discovery?.appFailure = nil
        }

        discoveryTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.discoveryDebounce)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            switch state.tab {
            case .servers: await fetchGuilds(for: state.serverRequest, appending: false)
            case .apps: await fetchApps(for: state.appRequest, appending: false)
            }
        }
    }

    func loadMoreDiscoveryGuilds() {
        guard let state = model.discovery else { return }
        discoveryPageTask?.cancel()
        model.discovery?.isLoading = true
        discoveryPageTask = Task { [weak self] in
            await self?.fetchGuilds(
                for: state.serverRequest,
                appending: true,
                offset: state.page.guilds.count
            )
        }
    }

    func loadMoreDirectoryApps() {
        guard let state = model.discovery else { return }
        discoveryPageTask?.cancel()
        model.discovery?.isLoadingApps = true
        var request = state.appRequest
        request.page = state.appPage + 1
        discoveryPageTask = Task { [weak self] in
            await self?.fetchApps(for: request, appending: true)
        }
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryPageTask?.cancel()
        discoveryPageTask = nil
    }

    // MARK: Servers

    private func fetchGuilds(
        for request: DiscoveryState.ServerRequest,
        appending: Bool,
        offset: Int = 0
    ) async {
        defer {
            if model.discovery?.serverRequest == request { model.discovery?.isLoading = false }
        }
        do {
            let page: DiscoveryPage
            if request.isSearch {
                page = try await rest.searchDiscoverableGuilds(
                    query: request.query,
                    categoryID: request.categoryID,
                    offset: offset,
                    // The facet is asked for once per question, on its first
                    // page. Asking again for page two would be the same answer
                    // at the cost of a wider response.
                    wantsCounts: offset == 0
                )
            } else {
                page = try await rest.discoverableGuilds(
                    categoryID: request.categoryID,
                    offset: offset
                )
            }
            // **The answer is checked against the question, not against "is
            // something open".** Three inputs move this page and any of them
            // can change while a request is out.
            guard !Task.isCancelled, model.discovery?.serverRequest == request else { return }
            if appending {
                model.discovery?.page.guilds.append(contentsOf: page.guilds)
                model.discovery?.page.total = page.total
                model.discovery?.page.offset = page.offset
            } else {
                model.discovery?.page = page
                // A fresh grid is a fresh load, and the id is what ties a click
                // on one of its cards back to it.
                model.discovery?.loadID = Self.mintLoadID()
            }
            Self.trace("discovery: \(page.guilds.count) of \(page.total) servers")
        } catch {
            guard !Task.isCancelled, model.discovery?.serverRequest == request else { return }
            model.discovery?.failure = Self.discoveryFailure(error)
            Self.trace("discovery: servers failed — \(Self.describe(error))")
        }
    }

    // MARK: Apps

    private func fetchApps(for request: DiscoveryState.AppRequest, appending: Bool) async {
        defer {
            if model.discovery?.appRequest.query == request.query,
               model.discovery?.appRequest.categoryID == request.categoryID
            {
                model.discovery?.isLoadingApps = false
            }
        }
        do {
            let page = try await rest.directoryApps(
                query: request.query,
                categoryID: request.categoryID,
                page: request.page,
                locale: metadata.locale
            )
            guard !Task.isCancelled,
                  model.discovery?.appRequest.query == request.query,
                  model.discovery?.appRequest.categoryID == request.categoryID
            else { return }
            if appending {
                model.discovery?.apps.append(contentsOf: page.apps)
            } else {
                model.discovery?.apps = page.apps
            }
            model.discovery?.appPage = page.page
            model.discovery?.appPageCount = page.pageCount
            Self.trace("discovery: \(page.apps.count) apps, page \(page.page)/\(page.pageCount)")
        } catch {
            guard !Task.isCancelled else { return }
            model.discovery?.appFailure = Self.discoveryFailure(error)
            Self.trace("discovery: apps failed — \(Self.describe(error))")
        }
    }

    /// "You Might Also Like", once per app.
    ///
    /// **Absent means not asked and empty means asked-and-none**, the same
    /// distinction every other table in this app draws — collapsing them makes
    /// the page re-ask on every visit for an app that has no neighbours.
    func loadSimilarApps(_ id: ApplicationID) {
        guard model.similarDirectoryApps[id] == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                model.similarDirectoryApps[id] =
                    try await rest.similarApps(to: id, locale: metadata.locale)
            } catch {
                model.similarDirectoryApps[id] = []
                Self.trace("discovery: similar apps for \(id.rawValue) failed")
            }
        }
    }

    // MARK: The headings

    /// Both category lists, once per session.
    ///
    /// **Two routes over two id spaces**, and neither changes in the lifetime of
    /// a session — Discord has shipped the same seventeen primary server
    /// headings and the same five app ones for years. A latch each, because one
    /// failing must not cost the other.
    private func loadDiscoveryCategories() {
        // **`metadata.locale`, never `Locale.current`.** This shipped as
        // `Locale.current.identifier(.bcp47)` and both category routes came back
        // empty on a live account: on a Mac with a regional override that
        // identifier is `en-US-u-rg-mdzzzz`, a perfectly valid BCP-47 tag that
        // Discord does not accept. `ClientMetadata.locale` is
        // `Locale.preferredLanguages.first` — `en-US` — and it is what every
        // other route in this app sends, including the two the app directory
        // already used. Two sources for one fact, and the wrong one failed
        // silently: the grid filled, the chips did not.
        let locale = metadata.locale
        if !hasLoadedDiscoveryCategories {
            hasLoadedDiscoveryCategories = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    model.discovery?.categories = try await rest.discoveryCategories(locale: locale)
                } catch {
                    // No notice: the grid works without headings, it simply
                    // cannot be browsed by one.
                    hasLoadedDiscoveryCategories = false
                    Self.trace("discovery: categories failed — \(Self.describe(error))")
                }
            }
        }
        guard !hasLoadedAppDirectoryCategories else { return }
        hasLoadedAppDirectoryCategories = true
        Task { [weak self] in
            guard let self else { return }
            do {
                model.discovery?.appCategories =
                    try await rest.appDirectoryCategories(locale: locale)
            } catch {
                hasLoadedAppDirectoryCategories = false
                Self.trace("discovery: app categories failed — \(Self.describe(error))")
            }
        }
    }

    // MARK: Shared

    /// Long enough to skip the characters somebody types on the way to a word.
    /// The same value the quick switcher's game search uses, for the same
    /// reason and so the two fields feel identical.
    static let discoveryDebounce = Duration.milliseconds(180)

    /// A load id in Discord's own shape: a bare 32-character hex string, no
    /// dashes. Captured as `5864989d991ef71a5eea43e317aff5e7`.
    static func mintLoadID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Why discovery did not answer, in words somebody can act on.
    static func discoveryFailure(_ error: any Error) -> String {
        switch error as? DiscordREST.Failure {
        case .api(_, let code, _) where code == Self.serverLimitCode:
            // Captured: the reader's first attempt at previewing Minecraft was
            // refused with this, and they had to leave a server first. It is
            // worth its own sentence because nothing about the card explains it.
            "You're in 100 servers, which is the limit. Leave one to look at another."
        case .transport:
            "Couldn't reach Discord. Check your connection."
        case .api(_, _, let message?) where !message.isEmpty:
            message
        default:
            "Discovery didn't answer. Try again in a moment."
        }
    }

    /// `30001` — "You are at the 100 server limit."
    ///
    /// **A lurk counts against it.** That is the surprising half: previewing a
    /// server you have not joined still occupies one of the hundred, so an
    /// account at the cap cannot even look. Captured in
    /// `join discoverable server.har`, where the first `lurker=true` was refused
    /// with this code and the second succeeded only after a server was left.
    static let serverLimitCode = 30001
}
