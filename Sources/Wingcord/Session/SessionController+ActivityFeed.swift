import Foundation
import WingcordCore
import WingcordNet

// MARK: - The reader's activity feed
//
// Discord's `ContentInventoryManager` (`819235`): ask as the connection opens
// and when the window comes forward, then again when the feed says it has
// expired — or, for a feed that promises to, when the gateway says it went
// stale. A failed ask is retried four times, a minute and then doubling, with
// a little jitter so a fleet of clients does not come back in step.

extension SessionController {

    /// Asks for the feed. Not while it is hidden and already held — Discord's
    /// own gate — and never twice at once.
    func loadActivityFeed(force: Bool = false) {
        let feed = model.activityFeed
        guard !feed.isLoading else { return }
        if !force, AppSettings.shared.hidesActivityCards, feed.inbox != nil { return }
        model.activityFeed.isLoading = true
        let token = feed.inbox?.refreshToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let inbox = try await rest.activityInbox(refreshToken: token)
                model.activityFeed.inbox = inbox
                model.activityFeed.failures = 0
                model.activityFeed.isLoading = false
                prefetchActivityArt(inbox)
                // A feed the gateway will call stale waits for that; any other
                // waits for its own expiry.
                scheduleActivityFeed(at: inbox.announcesStaleness ? nil : inbox.expiresAt)
            } catch {
                Self.trace("activity feed failed: \(Self.describe(error))")
                model.activityFeed.isLoading = false
                let failures = model.activityFeed.failures
                guard failures < 4 else { return }
                model.activityFeed.failures = failures + 1
                let backoff = 60 * pow(2, Double(failures)) + Double.random(in: 0 ... 120 * Double(failures + 1))
                scheduleActivityFeed(at: Date(timeIntervalSinceNow: backoff))
            }
        }
    }

    /// Asks when there is no feed yet, or the one held has expired — the
    /// window coming forward, the section shown again.
    func loadActivityFeedIfDue() {
        let inbox = model.activityFeed.inbox
        guard inbox == nil || (inbox?.expiresAt ?? .distantPast) <= .now else { return }
        loadActivityFeed()
    }

    /// `CONTENT_INVENTORY_INBOX_STALE` — ask again after the time it names.
    func activityFeedWentStale(after delay: TimeInterval?) {
        scheduleActivityFeed(at: Date(timeIntervalSinceNow: delay ?? 30))
    }

    private func scheduleActivityFeed(at date: Date?) {
        activityFeedTask?.cancel()
        activityFeedTask = nil
        guard let date else { return }
        activityFeedTask = Task { [weak self] in
            let wait = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.loadActivityFeed()
        }
    }

    /// The games' and activities' own pictures, which the cards draw.
    private func prefetchActivityArt(_ inbox: ActivityInbox) {
        var games: [ApplicationID] = []
        var applications: [ApplicationID] = []
        for entry in inbox.entries {
            switch entry.activity.subject {
            case .game(_, let id?): games.append(id)
            case .activity(_, let id?): applications.append(id)
            default: break
            }
        }
        if !applications.isEmpty || !games.isEmpty { model.resolveApplications(applications + games) }
        guard !games.isEmpty else { return }
        Task { [weak self] in await self?.loadGames(ids: games) }
    }

    /// Asks the gateway for the feed's authors this server has not sent —
    /// Discord's `requestMember` for each, so the section can tell who here
    /// may see the channel.
    func requestActivityAuthors(inGuild guildID: GuildID) {
        guard let inbox = model.activityFeed.inbox, let socket else { return }
        let held = model.members[guildID] ?? [:]
        let missing = Array(Set(inbox.entries.map(\.activity.authorID)).filter { held[$0] == nil })
        guard !missing.isEmpty else { return }
        Task { await socket.requestGuildMembers(guildID: guildID, userIDs: missing) }
    }

    /// Answers somebody's activity in a direct message, carrying the entry —
    /// Discord's `428249`, for a reply and for an emoji alike. Answers whether
    /// it went.
    func replyToActivity(_ entry: ActivityFeedEntry, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let conversation = try await resolveDirectMessage(with: entry.activity.authorID)
            _ = try await rest.sendMessage(
                in: conversation,
                content: trimmed,
                nonce: Self.nonce(),
                inventoryEntry: entry.raw
            )
            return true
        } catch {
            Self.trace("activity reply \(entry.id) failed: \(Self.describe(error))")
            model.reportActionFailure(Self.describe(error))
            return false
        }
    }
}
