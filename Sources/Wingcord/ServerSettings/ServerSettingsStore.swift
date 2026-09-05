import Foundation
import Observation
import WingcordCore
import WingcordNet

// MARK: - What the settings window knows
//
// One store per open window, built when the window opens and thrown away when it
// closes. **Deliberately not part of `AppModel`.**
//
// `AppModel` is copied and observed by the transcript, the rail, the roster and
// the composer, and it is written to several times a second by inbound messages.
// Twenty administrative tables — a hundred audit log entries, every ban, every
// webhook — hanging off it would be paid for on every one of those writes, by
// every surface, for a window almost nobody has open. So this is its own object
// with its own lifetime, and the only thing it shares is the REST client.
//
// THE LOADING RULE: **a section fetches when it is first opened, and never
// again.** Not on window open — that would be eighteen requests for a reader who
// came to rename the server — and not on every visit, because stepping back to a
// page must not re-ask. `Loadable` is what makes "asked and empty" different
// from "not asked", which is the same distinction the server *reader* pages had
// to make and for the same reason.

/// A resource that has to be fetched.
///
/// The `.failed` case carries its message so a page can say *why* rather than
/// drawing an empty table — an administrator who lacks a permission gets told
/// so, instead of concluding the server has no bans.
enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Whether a fetch should start. Idle and failed both qualify — a failure is
    /// worth retrying when somebody comes back to the page — but `loading` and
    /// `loaded` do not, which is the whole of the "ask once" rule.
    var wantsFetch: Bool {
        switch self {
        case .idle, .failed: true
        case .loading, .loaded: false
        }
    }

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@MainActor
@Observable
final class ServerSettingsStore {
    let guildID: GuildID
    /// The reader's own permissions here, resolved once when the window opened.
    /// Sections are filtered by it and nothing re-derives it.
    let permissions: Permissions

    // MARK: The tables

    var settings: Loadable<GuildSettings> = .idle
    var profile: Loadable<GuildProfile> = .idle
    var roles: Loadable<[Role]> = .idle
    var roleMemberCounts: [RoleID: Int] = [:]
    var emoji: Loadable<[GuildEmoji]> = .idle
    var stickers: Loadable<[GuildSticker]> = .idle
    var sounds: Loadable<[SoundboardSound]> = .idle
    var soundUploaders: [String: UserID] = [:]
    var invites: Loadable<[GuildInvite]> = .idle
    var bans: Loadable<[GuildBan]> = .idle
    var integrations: Loadable<[GuildIntegration]> = .idle
    var webhooks: Loadable<[GuildWebhook]> = .idle
    var template: Loadable<GuildTemplate?> = .idle
    var autoModRules: Loadable<[AutoModRule]> = .idle
    var auditLog: Loadable<AuditLogPage> = .idle
    var joinForm: Loadable<JoinApplicationForm> = .idle
    var discoveryRequirements: Loadable<DiscoveryRequirements> = .idle
    var widget: Loadable<GuildWidgetSettings> = .idle
    var events: Loadable<[ScheduledEvent]> = .idle
    var members: Loadable<MemberPage> = .idle
    /// One list per tab, because the three are three separate requests and a
    /// reader who opens Pending must not be shown Approved's spinner.
    var joinRequests: [GuildJoinRequest.Status: Loadable<[GuildJoinRequest]>] = [:]
    var onboarding: Loadable<GuildOnboarding> = .idle
    var serverGuide: Loadable<ServerGuide> = .idle

    /// People named by a table — emoji uploaders, ban subjects, invite creators.
    /// One shared table, because four pages name the same handful of
    /// administrators and four copies is four fetches.
    var people: [UserID: AuditLogUser] = [:]

    /// Channels, for every menu on every page that picks one.
    ///
    /// Handed in from `AppModel` rather than fetched: the window is opened from
    /// a server the reader is already in, and its channel list is already
    /// resident and already correct.
    var channels: [ChannelSummary]

    // MARK: Writing

    /// What the save banner says. One at a time, because two saves in flight on
    /// one page is a page whose controls disagree with each other.
    var save: SaveState = .idle

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    /// A page of the members table, with the total the search reported.
    ///
    /// The total is separate from `rows.count` and both matter: a server of
    /// forty thousand answers 250 rows and a total of 40,000, and a page that
    /// showed only the first number would be telling the reader the server is
    /// smaller than it is.
    struct MemberPage: Sendable {
        var rows: [GuildMemberRow]
        var total: Int
    }

    /// A channel, as a picker needs it.
    struct ChannelSummary: Hashable, Sendable, Identifiable {
        var id: ChannelID
        var name: String
        var kind: ChannelKind
        var categoryName: String?
        /// Whether `@everyone` can read it. The onboarding and community pages
        /// both state a requirement about this, and neither can compute it.
        var isPublic: Bool
    }

    private let rest: DiscordREST
    /// The in-flight fetch per section, so leaving and re-entering a page does
    /// not stack two of the same request.
    private var tasks: [ServerSettingsSection: Task<Void, Never>] = [:]
    /// Games already resolved, by id. See `resolveGames`.
    private var gameCache: [ApplicationID: GameSummary] = [:]
    /// Clears the "Saved" tick after a beat. Replaced rather than stacked — two
    /// quick saves would otherwise have the first one's timer clear the second
    /// one's tick early.
    private var saveResetTask: Task<Void, Never>?

    init(
        guildID: GuildID,
        permissions: Permissions,
        channels: [ChannelSummary],
        rest: DiscordREST
    ) {
        self.guildID = guildID
        self.permissions = permissions
        self.channels = channels
        self.rest = rest
    }

    /// Cancels everything in flight.
    ///
    /// Called from the window's `onDisappear` rather than from `deinit`: this is
    /// a `@MainActor` type, `deinit` is not isolated to it, and reaching a
    /// main-actor property from there is exactly the data race Swift 6 refuses
    /// to compile. An explicit teardown at the one place the window goes away is
    /// both correct and easier to find than a destructor.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        saveResetTask?.cancel()
    }

    // MARK: - Loading

    /// Fetches what a section needs, once.
    ///
    /// Called from the pane's `task`, so it runs when the page appears and is
    /// cancelled with it. Sections that share a table — Profile and Tag are one
    /// route, Safety and Community are both the guild — get it once between
    /// them, because the guard is on the *table* rather than on the section.
    func load(_ section: ServerSettingsSection) {
        guard tasks[section] == nil else { return }
        let task = Task { [weak self] in
            await self?.fetch(section)
            self?.tasks[section] = nil
        }
        tasks[section] = task
    }

    private func fetch(_ section: ServerSettingsSection) async {
        switch section {
        case .profile, .tag:
            await loadGuild()
            await loadProfile()
        case .engagement:
            await loadGuild()
            await loadWidget()
        case .emoji:
            await loadEmoji()
        case .stickers:
            await loadStickers()
        case .soundboard:
            await loadSounds()
        case .roles:
            await loadRoles()
        case .invites:
            await loadInvites()
        case .access:
            await loadGuild()
            await loadJoinForm()
            await loadDiscoveryRequirements()
        case .integrations:
            await loadIntegrations()
        case .webhooks:
            await loadWebhooks()
        case .safety:
            await loadGuild()
            await loadAutoModRules()
        case .auditLog:
            await loadAuditLog()
        case .bans:
            await loadBans()
        case .community:
            await loadGuild()
        case .onboarding:
            await loadOnboarding()
        case .serverGuide:
            await loadServerGuide()
        case .template:
            await loadTemplate()
        case .events:
            await loadEvents()
        case .members:
            // The join form decides whether the applicant tabs exist at all,
            // so it is fetched with the list rather than when a tab is pressed.
            await loadMembers()
            await loadJoinForm()
        case .channels:
            // The channel list is resident. What this page needs beyond it is
            // the delete gate's two inputs — a guide task or a default channel
            // is what makes a channel undeletable, and neither is knowable from
            // the channel itself.
            await loadServerGuide()
            await loadOnboarding()
        }
    }

    /// Runs a fetch into a `Loadable`, with the "ask once" guard and the
    /// error-to-message conversion in one place.
    ///
    /// A generic over the key path rather than eighteen near-identical
    /// functions: the eighteen differ only in which route they call, and the
    /// bookkeeping around them is exactly the thing that must not drift.
    private func fill<Value>(
        _ keyPath: ReferenceWritableKeyPath<ServerSettingsStore, Loadable<Value>>,
        _ work: @escaping () async throws -> Value
    ) async {
        guard self[keyPath: keyPath].wantsFetch else { return }
        self[keyPath: keyPath] = .loading
        do {
            let value = try await work()
            guard !Task.isCancelled else { return }
            self[keyPath: keyPath] = .loaded(value)
        } catch {
            guard !Task.isCancelled else { return }
            self[keyPath: keyPath] = .failed(Self.describe(error))
        }
    }

    private func loadGuild() async {
        await fill(\.settings) { [rest, guildID] in
            try await rest.guildSettings(of: guildID)
        }
        // The guild carries its roles, so the roles page has them already and
        // its own fetch is only for the reorder that follows.
        if case .loaded = roles {} else if case .loaded = settings {
            await loadRoles()
        }
    }

    private func loadProfile() async {
        await fill(\.profile) { [rest, guildID] in
            try await rest.guildProfile(of: guildID)
        }
    }

    private func loadRoles() async {
        await fill(\.roles) { [rest, guildID] in
            try await rest.guildRoles(in: guildID)
        }
        // The counts are the largest answer on the page and worth nothing to
        // somebody who never opens it — the same trade §5.5 records for the
        // reader's side. Failure is silent: a role row without a count is a row
        // missing one number, not a broken page.
        guard roleMemberCounts.isEmpty else { return }
        roleMemberCounts = (try? await rest.roleMemberCounts(of: guildID)) ?? [:]
    }

    private func loadEmoji() async {
        await fill(\.emoji) { [rest, guildID] in try await rest.guildEmojis(in: guildID) }
    }

    private func loadStickers() async {
        await fill(\.stickers) { [rest, guildID] in try await rest.guildStickers(in: guildID) }
    }

    private func loadSounds() async {
        guard sounds.wantsFetch else { return }
        sounds = .loading
        do {
            let answer = try await rest.guildSoundboardSounds(in: guildID)
            guard !Task.isCancelled else { return }
            sounds = .loaded(answer.sounds)
            soundUploaders = answer.uploaders
        } catch {
            guard !Task.isCancelled else { return }
            sounds = .failed(Self.describe(error))
        }
    }

    private func loadInvites() async {
        await fill(\.invites) { [rest, guildID] in try await rest.guildInvites(in: guildID) }
    }

    private func loadBans() async {
        await fill(\.bans) { [rest, guildID] in try await rest.guildBans(in: guildID) }
    }

    private func loadIntegrations() async {
        await fill(\.integrations) { [rest, guildID] in
            try await rest.guildIntegrations(in: guildID)
        }
    }

    private func loadWebhooks() async {
        await fill(\.webhooks) { [rest, guildID] in try await rest.guildWebhooks(in: guildID) }
    }

    /// The events, with the reader's own interest folded in.
    ///
    /// Three routes for one page, and they are separate on the wire: the list,
    /// the reader's RSVPs, and a per-event count. The count is asked for per
    /// event because there is no bulk form of it — bounded by how many events a
    /// server has, which is single digits.
    private func loadEvents() async {
        await fill(\.events) { [rest, guildID] in
            let list = try await rest.scheduledEvents(in: guildID)
            // Failing to learn the reader's own RSVPs is not a reason to have no
            // events page, so this one degrades to "interested in nothing".
            let interested = (try? await rest.interestedEventIDs(in: guildID)) ?? []
            var resolved: [ScheduledEvent] = []
            resolved.reserveCapacity(list.count)
            for var event in list {
                event.isInterested = interested.contains(event.id)
                if event.interestedCount == nil {
                    event.interestedCount = try? await rest.interestedCount(
                        for: event.id, in: guildID
                    )
                }
                resolved.append(event)
            }
            return resolved
        }
    }

    /// The members table.
    ///
    /// **A 202 is retried, not reported.** An unindexed guild answers "index not
    /// yet available" with a `retry_after`, and treating that as an empty result
    /// would draw an empty server. One retry: a second 202 is a server large
    /// enough that the index is genuinely still building, and a client that
    /// looped would sit there asking for minutes.
    private func loadMembers(sort: GuildMemberRow.Sort = .joinedNewest) async {
        guard members.wantsFetch else { return }
        members = .loading
        do {
            var answer = try await rest.searchMembers(in: guildID, sort: sort)
            if answer == nil {
                try await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                answer = try await rest.searchMembers(in: guildID, sort: sort)
            }
            guard !Task.isCancelled else { return }
            guard let answer else {
                members = .failed("This server's member index is still building. Try again shortly.")
                return
            }
            members = .loaded(MemberPage(rows: answer.rows, total: answer.total))
        } catch {
            guard !Task.isCancelled else { return }
            members = .failed(Self.describe(error))
        }
    }

    /// Re-runs the search with a different ordering.
    ///
    /// Its own entry point because `loadMembers` will not re-fetch a loaded
    /// table — that guard is the whole "ask once" rule, and a sort is the one
    /// thing that has to get past it.
    func reloadMembers(sort: GuildMemberRow.Sort) {
        members = .idle
        Task { await loadMembers(sort: sort) }
    }

    /// One tab of applicants, fetched when it is first opened.
    func load(joinRequests status: GuildJoinRequest.Status) {
        guard (joinRequests[status] ?? .idle).wantsFetch else { return }
        joinRequests[status] = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await rest.joinRequests(in: guildID, status: status)
                guard !Task.isCancelled else { return }
                joinRequests[status] = .loaded(list)
            } catch {
                guard !Task.isCancelled else { return }
                joinRequests[status] = .failed(Self.describe(error))
            }
        }
    }

    private func loadTemplate() async {
        await fill(\.template) { [rest, guildID] in try await rest.guildTemplate(of: guildID) }
    }

    private func loadAutoModRules() async {
        await fill(\.autoModRules) { [rest, guildID] in try await rest.autoModRules(in: guildID) }
    }

    private func loadWidget() async {
        await fill(\.widget) { [rest, guildID] in try await rest.widgetSettings(of: guildID) }
    }

    private func loadJoinForm() async {
        await fill(\.joinForm) { [rest, guildID] in
            try await rest.joinApplicationForm(of: guildID)
        }
    }

    private func loadDiscoveryRequirements() async {
        await fill(\.discoveryRequirements) { [rest, guildID] in
            try await rest.discoveryRequirements(of: guildID)
        }
    }

    private func loadOnboarding() async {
        await fill(\.onboarding) { [rest, guildID] in try await rest.onboarding(of: guildID) }
    }

    private func loadServerGuide() async {
        await fill(\.serverGuide) { [rest, guildID] in try await rest.serverGuide(of: guildID) }
    }

    private func loadAuditLog() async {
        await fill(\.auditLog) { [rest, guildID] in try await rest.auditLog(in: guildID) }
        if case .loaded(let page) = auditLog { people.merge(page.users) { current, _ in current } }
    }

    /// The next page of the audit log, appended.
    ///
    /// Its own entry point rather than part of `load`, because paging is a
    /// press rather than an appearance — and because appending is not the same
    /// as filling: the `Loadable` stays `.loaded` throughout, so the rows
    /// already on screen do not flash back to a spinner.
    func loadMoreAuditLog() async {
        guard case .loaded(let page) = auditLog, let before = page.oldestEntryID else { return }
        do {
            let next = try await rest.auditLog(in: guildID, before: before)
            guard !next.entries.isEmpty else { return }
            auditLog = .loaded(page.appending(next))
            people.merge(next.users) { current, _ in current }
        } catch {
            // A failed page-two leaves page one alone. Turning the whole log
            // into an error because the *second* request failed throws away
            // fifty rows the reader is looking at.
            Self.trace("audit log page failed: \(Self.describe(error))")
        }
    }

    // MARK: - Writing
    //
    // Every write goes through `perform`, which owns the save banner and the
    // one rule that matters on this surface: **the response is the truth, not
    // the optimistic value.** Discord rounds a soundboard volume, renumbers role
    // positions, and rewrites a features array — a client that kept its own copy
    // would disagree with the server about what it had just saved.

    /// Runs a write, banners it, and stores whatever came back.
    @discardableResult
    func perform(_ work: @escaping () async throws -> Void) async -> Bool {
        saveResetTask?.cancel()
        save = .saving
        do {
            try await work()
            save = .saved
            saveResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // Only clears its OWN tick. A save that started since has
                // already replaced this task, and this branch does not run.
                if self?.save == .saved { self?.save = .idle }
            }
            return true
        } catch {
            save = .failed(Self.describe(error))
            return false
        }
    }

    // MARK: Guild

    func saveCommunitySettings(
        description: String?,
        features: Set<String>,
        preferredLocale: String,
        rulesChannelID: ChannelID?,
        publicUpdatesChannelID: ChannelID?,
        safetyAlertsChannelID: ChannelID?
    ) async {
        await perform { [self] in
            let updated = try await rest.updateCommunitySettings(
                in: guildID,
                description: description,
                features: features,
                preferredLocale: preferredLocale,
                rulesChannelID: rulesChannelID,
                publicUpdatesChannelID: publicUpdatesChannelID,
                safetyAlertsChannelID: safetyAlertsChannelID
            )
            settings = .loaded(updated)
        }
    }

    func saveEngagement(
        systemChannelID: ChannelID?,
        systemChannelFlags: SystemChannelFlags,
        defaultMessageNotifications: NotificationLevel,
        afkChannelID: ChannelID?,
        afkTimeout: Int
    ) async {
        await perform { [self] in
            settings = .loaded(try await rest.updateEngagementSettings(
                in: guildID,
                systemChannelID: systemChannelID,
                systemChannelFlags: systemChannelFlags,
                defaultMessageNotifications: defaultMessageNotifications,
                afkChannelID: afkChannelID,
                afkTimeout: afkTimeout
            ))
        }
    }

    func saveContentLevel(_ level: ContentLevel) async {
        await perform { [self] in
            settings = .loaded(try await rest.updateContentLevel(in: guildID, level))
        }
    }

    func saveModerationLevels(
        verification: VerificationLevel,
        explicitContent: ExplicitContentFilter
    ) async {
        await perform { [self] in
            settings = .loaded(try await rest.updateModerationLevels(
                in: guildID,
                verificationLevel: verification,
                explicitContentFilter: explicitContent
            ))
        }
    }

    func saveWidget(isEnabled: Bool, channelID: ChannelID?) async {
        await perform { [self] in
            widget = .loaded(try await rest.updateWidget(
                in: guildID, isEnabled: isEnabled, channelID: channelID
            ))
        }
    }

    // MARK: Profile and tag

    func saveProfile(
        _ profile: GuildProfile,
        icon: ImageData?? = nil,
        customBanner: ImageData?? = nil
    ) async {
        await perform { [self] in
            self.profile = .loaded(
                try await rest.updateGuildProfile(profile, icon: icon, customBanner: customBanner)
            )
        }
    }

    // MARK: Roles

    func createRole() async {
        await perform { [self] in
            let role = try await rest.createRole(in: guildID)
            var current = roles.value ?? []
            current.append(role)
            roles = .loaded(current)
        }
    }

    func saveRole(_ role: Role) async {
        await perform { [self] in
            let updated = try await rest.updateRole(role, in: guildID)
            var current = roles.value ?? []
            if let index = current.firstIndex(where: { $0.id == updated.id }) {
                current[index] = updated
            }
            roles = .loaded(current)
        }
    }

    func deleteRole(_ roleID: RoleID) async {
        await perform { [self] in
            try await rest.deleteRole(roleID, in: guildID)
            roles = .loaded((roles.value ?? []).filter { $0.id != roleID })
        }
    }

    /// Applies a drag.
    ///
    /// **The whole list comes back and the whole list is stored.** Discord
    /// renumbers every role a move displaced, so keeping the optimistic order
    /// would leave the page one drag ahead of the truth and the next drag would
    /// be computed from a position nobody holds.
    func reorderRoles(_ positions: [(id: RoleID, position: Int)]) async {
        await perform { [self] in
            roles = .loaded(try await rest.reorderRoles(in: guildID, positions: positions))
        }
    }

    // MARK: Expression

    func createEmoji(name: String, image: ImageData) async {
        await perform { [self] in
            guard let emojiValue = try await rest.createEmoji(
                in: guildID, name: name, image: image
            ) else { return }
            emoji = .loaded((emoji.value ?? []) + [emojiValue])
        }
    }

    func renameEmoji(_ emojiID: EmojiID, to name: String) async {
        await perform { [self] in
            guard let updated = try await rest.renameEmoji(emojiID, in: guildID, to: name)
            else { return }
            var current = emoji.value ?? []
            if let index = current.firstIndex(where: { $0.id == emojiID }) {
                // The rename response does not carry the uploader; the row's
                // "added by" would blank if the whole entry were replaced.
                current[index].name = updated.name
            }
            emoji = .loaded(current)
        }
    }

    func deleteEmoji(_ emojiID: EmojiID) async {
        await perform { [self] in
            try await rest.deleteEmoji(emojiID, in: guildID)
            emoji = .loaded((emoji.value ?? []).filter { $0.id != emojiID })
        }
    }

    func createSticker(
        name: String,
        relatedEmoji: String,
        description: String?,
        file: Data,
        filename: String,
        contentType: String
    ) async {
        await perform { [self] in
            guard let sticker = try await rest.createSticker(
                in: guildID,
                name: name,
                relatedEmoji: relatedEmoji,
                description: description,
                file: file,
                filename: filename,
                contentType: contentType
            ) else { return }
            stickers = .loaded((stickers.value ?? []) + [sticker])
        }
    }

    func saveSticker(
        _ stickerID: UInt64,
        name: String,
        relatedEmoji: String,
        description: String?
    ) async {
        await perform { [self] in
            guard let updated = try await rest.updateSticker(
                stickerID,
                in: guildID,
                name: name,
                relatedEmoji: relatedEmoji,
                description: description
            ) else { return }
            var current = stickers.value ?? []
            if let index = current.firstIndex(where: { $0.id == stickerID }) {
                current[index] = updated
            }
            stickers = .loaded(current)
        }
    }

    func deleteSticker(_ stickerID: UInt64) async {
        await perform { [self] in
            try await rest.deleteSticker(stickerID, in: guildID)
            stickers = .loaded((stickers.value ?? []).filter { $0.id != stickerID })
        }
    }

    func createSound(
        name: String,
        sound: ImageData,
        volume: Double,
        emojiName: String?,
        emojiID: UInt64?
    ) async {
        await perform { [self] in
            guard let created = try await rest.createSoundboardSound(
                in: guildID,
                name: name,
                sound: sound,
                volume: volume,
                emojiName: emojiName,
                emojiID: emojiID
            ) else { return }
            sounds = .loaded((sounds.value ?? []) + [created])
        }
    }

    func saveSound(
        _ soundID: String,
        name: String,
        volume: Double,
        emojiName: String?,
        emojiID: UInt64?
    ) async {
        await perform { [self] in
            guard let updated = try await rest.updateSoundboardSound(
                soundID,
                in: guildID,
                name: name,
                volume: volume,
                emojiName: emojiName,
                emojiID: emojiID
            ) else { return }
            var current = sounds.value ?? []
            if let index = current.firstIndex(where: { $0.id == soundID }) { current[index] = updated }
            sounds = .loaded(current)
        }
    }

    func deleteSound(_ soundID: String) async {
        await perform { [self] in
            try await rest.deleteSoundboardSound(soundID, in: guildID)
            sounds = .loaded((sounds.value ?? []).filter { $0.id != soundID })
        }
    }

    // MARK: People

    func createInvite(in channelID: ChannelID, options: InviteOptions) async {
        await perform { [self] in
            guard let invite = try await rest.createInvite(in: channelID, options: options)
            else { return }
            invites = .loaded([invite] + (invites.value ?? []))
        }
    }

    func deleteInvite(_ code: String) async {
        await perform { [self] in
            try await rest.deleteInvite(code)
            invites = .loaded((invites.value ?? []).filter { $0.id != code })
        }
    }

    func unban(_ userID: UserID) async {
        await perform { [self] in
            try await rest.unban(userID, in: guildID)
            bans = .loaded((bans.value ?? []).filter { $0.id != userID })
        }
    }

    func saveJoinForm(_ form: JoinApplicationForm) async {
        await perform { [self] in
            joinForm = .loaded(try await rest.updateJoinApplicationForm(form))
        }
    }

    // MARK: Apps

    func deleteIntegration(_ id: UInt64) async {
        await perform { [self] in
            try await rest.deleteIntegration(id, in: guildID)
            integrations = .loaded((integrations.value ?? []).filter { $0.id != id })
        }
    }

    func createWebhook(in channelID: ChannelID) async {
        await perform { [self] in
            guard let webhook = try await rest.createWebhook(in: channelID) else { return }
            webhooks = .loaded((webhooks.value ?? []) + [webhook])
        }
    }

    func saveWebhook(_ id: UInt64, name: String, channelID: ChannelID?) async {
        await perform { [self] in
            guard let updated = try await rest.updateWebhook(
                id, name: name, channelID: channelID
            ) else { return }
            var current = webhooks.value ?? []
            if let index = current.firstIndex(where: { $0.id == id }) {
                // The update response drops the token. Keeping the row's own
                // means Copy Link still works after a rename.
                let token = current[index].token
                current[index] = updated
                if current[index].token == nil { current[index].token = token }
            }
            webhooks = .loaded(current)
        }
    }

    func deleteWebhook(_ id: UInt64) async {
        await perform { [self] in
            try await rest.deleteWebhook(id)
            webhooks = .loaded((webhooks.value ?? []).filter { $0.id != id })
        }
    }

    // MARK: Moderation

    func setAutoModRuleEnabled(_ id: UInt64, isEnabled: Bool) async {
        await perform { [self] in
            guard let updated = try await rest.setAutoModRuleEnabled(
                id, in: guildID, isEnabled: isEnabled
            ) else { return }
            var current = autoModRules.value ?? []
            if let index = current.firstIndex(where: { $0.id == id }) { current[index] = updated }
            autoModRules = .loaded(current)
        }
    }

    // MARK: Template

    func createTemplate(name: String, description: String?) async {
        await perform { [self] in
            template = .loaded(
                try await rest.createTemplate(in: guildID, name: name, description: description)
            )
        }
    }

    func saveTemplate(_ code: String, name: String, description: String?) async {
        await perform { [self] in
            template = .loaded(try await rest.updateTemplate(
                code, in: guildID, name: name, description: description
            ))
        }
    }

    func syncTemplate(_ code: String) async {
        await perform { [self] in
            template = .loaded(try await rest.syncTemplate(code, in: guildID))
        }
    }

    func deleteTemplate(_ code: String) async {
        await perform { [self] in
            try await rest.deleteTemplate(code, in: guildID)
            template = .loaded(nil)
        }
    }

    // MARK: Onboarding, the guide, community and AutoMod

    /// The three onboarding writes are three functions because **the route
    /// merges per field** — see `DiscordREST.setOnboardingChannels`. Sending all
    /// three together would work and would also make the Enable switch depend on
    /// what the prompt editor is holding, which is how a save races an edit.
    func saveOnboardingPrompts(_ prompts: [OnboardingDraft.Prompt]) async {
        await perform { [self] in
            onboarding = .loaded(
                try await rest.setOnboardingPrompts(in: guildID, prompts: prompts)
            )
        }
    }

    func saveOnboardingChannels(_ channelIDs: [ChannelID]) async {
        await perform { [self] in
            onboarding = .loaded(
                try await rest.setOnboardingChannels(in: guildID, defaultChannelIDs: channelIDs)
            )
        }
    }

    func setOnboardingEnabled(_ isEnabled: Bool) async {
        await perform { [self] in
            onboarding = .loaded(try await rest.setOnboardingEnabled(in: guildID, isEnabled: isEnabled))
        }
    }

    func saveServerGuide(_ guide: ServerGuide, isEnabled: Bool) async {
        await perform { [self] in
            serverGuide = .loaded(try await rest.updateServerGuide(guide, isEnabled: isEnabled))
        }
    }

    func enableCommunity(
        rules: DiscordREST.CommunityChannel,
        updates: DiscordREST.CommunityChannel,
        verification: VerificationLevel,
        notifications: NotificationLevel,
        explicitContent: ExplicitContentFilter
    ) async {
        await perform { [self] in
            guard let current = settings.value else { return }
            settings = .loaded(try await rest.enableCommunity(
                in: guildID,
                features: current.features,
                verificationLevel: verification,
                notifications: notifications,
                explicitContentFilter: explicitContent,
                rulesChannel: rules,
                updatesChannel: updates
            ))
            // Six community pages appear the moment this lands, and every one of
            // them is gated on a fetch that has not happened. Invalidated rather
            // than left stale.
            onboarding = .idle
            serverGuide = .idle
        }
    }

    func setFeature(_ feature: String, isOn: Bool) async {
        await perform { [self] in
            guard let current = settings.value else { return }
            settings = .loaded(try await rest.setGuildFeature(
                in: guildID, features: current.features, feature: feature, isOn: isOn
            ))
        }
    }

    func saveAutoModRule(_ draft: AutoModDraft, existing: UInt64?) async {
        await perform { [self] in
            // The validate step first, because Discord's regex is Rust-flavoured
            // and an `NSRegularExpression` check on this side would pass
            // patterns the server then refuses. A throw here names the pattern.
            try await rest.validateAutoModRule(in: guildID, draft)
            let saved: AutoModRule? = if let existing {
                try await rest.updateAutoModRule(existing, in: guildID, draft)
            } else {
                try await rest.createAutoModRule(in: guildID, draft)
            }
            guard let saved else { return }
            var current = autoModRules.value ?? []
            if let index = current.firstIndex(where: { $0.id == saved.id }) {
                current[index] = saved
            } else {
                current.append(saved)
            }
            autoModRules = .loaded(current)
        }
    }

    func deleteAutoModRule(_ ruleID: UInt64) async {
        await perform { [self] in
            try await rest.deleteAutoModRule(ruleID, in: guildID)
            autoModRules = .loaded((autoModRules.value ?? []).filter { $0.id != ruleID })
        }
    }

    // MARK: Channels

    func createChannel(name: String, kind: ChannelKind, isPrivate: Bool) async {
        await perform { [self] in
            guard let channel = try await rest.createChannel(
                in: guildID, name: name, kind: kind
            ) else { return }
            // **Private is not part of the create** — it is a denied
            // VIEW_CHANNEL bit on @everyone, applied afterwards. See §SM.13.
            if isPrivate {
                try await rest.setChannelPrivate(channel.id, in: guildID, isPrivate: true)
            }
            channels.append(ChannelSummary(
                id: channel.id,
                name: channel.name,
                kind: channel.kind,
                categoryName: nil,
                isPublic: !isPrivate
            ))
            channels.sort { $0.name < $1.name }
        }
    }

    func setChannelPrivate(_ channelID: ChannelID, isPrivate: Bool) async {
        await perform { [self] in
            try await rest.setChannelPrivate(channelID, in: guildID, isPrivate: isPrivate)
            if let index = channels.firstIndex(where: { $0.id == channelID }) {
                channels[index].isPublic = !isPrivate
            }
        }
    }

    func saveChannel(_ draft: ChannelDraft) async {
        await perform { [self] in
            guard let updated = try await rest.updateChannel(
                draft.id,
                name: draft.name,
                kind: draft.kind,
                topic: draft.topic,
                isAgeRestricted: draft.visibility.isAgeRestricted,
                isSpoiler: draft.visibility.isSpoiler,
                bitrate: draft.bitrate,
                userLimit: draft.userLimit,
                slowmodeSeconds: draft.slowmodeSeconds,
                autoArchiveMinutes: draft.autoArchiveMinutes
            ) else { return }
            if let index = channels.firstIndex(where: { $0.id == draft.id }) {
                channels[index].name = updated.name
                channels[index].kind = updated.kind
            }
        }
    }

    func deleteChannel(_ channelID: ChannelID) async {
        await perform { [self] in
            try await rest.deleteChannel(channelID)
            channels.removeAll { $0.id == channelID }
        }
    }

    /// Why a channel may not be deleted, or nil.
    ///
    /// Discord's own client refuses this locally and never asks the server, so
    /// this is a pre-check rather than a translated error — and if the server
    /// would in fact accept the delete, it is the only thing standing between an
    /// administrator and a Server Guide pointing at nothing.
    func deleteRefusal(for channelID: ChannelID) -> ChannelDeleteGate.Refusal? {
        ChannelDeleteGate.refusal(
            for: channelID,
            guide: serverGuide.value,
            onboarding: onboarding.value,
            chattableDefaults: (onboarding.value?.defaultChannelIDs ?? [])
                .filter { id in channels.first { $0.id == id }?.isPublic ?? false }
                .count
        )
    }

    // MARK: Members

    func kick(_ userID: UserID) async {
        await perform { [self] in
            try await rest.kickMember(userID, in: guildID)
            removeMemberRow(userID)
        }
    }

    func ban(_ userID: UserID) async {
        await perform { [self] in
            try await rest.banMember(userID, in: guildID)
            removeMemberRow(userID)
            // The bans table, if it has been looked at, is now one entry short
            // of the truth. Invalidated rather than patched: this client does
            // not have the ban's reason, and inventing an empty one would put a
            // row on that page saying something the server did not say.
            bans = .idle
        }
    }

    func timeOut(_ userID: UserID, until: Date?) async {
        await perform { [self] in
            try await rest.timeOutMember(userID, in: guildID, until: until)
            guard var page = members.value else { return }
            if let index = page.rows.firstIndex(where: { $0.id == userID }) {
                page.rows[index].timedOutUntil = until
            }
            members = .loaded(page)
        }
    }

    func resolve(_ requestID: UInt64, approve: Bool, reason: String? = nil) async {
        await perform { [self] in
            try await rest.resolveJoinRequest(
                requestID, in: guildID, approve: approve, reason: reason
            )
            // The row leaves Pending and joins one of the other two. Both of
            // those are invalidated rather than patched, because an approval
            // also changes the members table and this client does not have the
            // member record the approval created.
            if case .loaded(let pending) = joinRequests[.submitted] ?? .idle {
                joinRequests[.submitted] = .loaded(pending.filter { $0.id != requestID })
            }
            joinRequests[approve ? .approved : .rejected] = .idle
            if approve { members = .idle }
        }
    }

    private func removeMemberRow(_ userID: UserID) {
        guard var page = members.value else { return }
        page.rows.removeAll { $0.id == userID }
        page.total = max(0, page.total - 1)
        members = .loaded(page)
    }

    // MARK: Events

    func createEvent(
        name: String,
        description: String?,
        location: ScheduledEvent.Location,
        startsAt: Date,
        endsAt: Date?,
        recurrence: Recurrence?,
        cover: ImageData?
    ) async {
        await perform { [self] in
            guard let event = try await rest.createEvent(
                in: guildID,
                name: name,
                description: description,
                location: location,
                startsAt: startsAt,
                endsAt: endsAt,
                recurrence: recurrence,
                cover: cover
            ) else { return }
            events = .loaded((events.value ?? []) + [event])
        }
    }

    func saveEvent(
        _ eventID: UInt64,
        name: String,
        description: String?,
        location: ScheduledEvent.Location,
        startsAt: Date,
        endsAt: Date?,
        recurrence: Recurrence?,
        cover: ImageData?
    ) async {
        await perform { [self] in
            guard let updated = try await rest.updateEvent(
                eventID,
                in: guildID,
                name: name,
                description: description,
                location: location,
                startsAt: startsAt,
                endsAt: endsAt,
                recurrence: recurrence,
                cover: cover
            ) else { return }
            replaceEvent(updated)
        }
    }

    func cancelEvent(_ eventID: UInt64) async {
        await perform { [self] in
            guard let updated = try await rest.cancelEvent(eventID, in: guildID) else { return }
            replaceEvent(updated)
        }
    }

    func deleteEvent(_ eventID: UInt64) async {
        await perform { [self] in
            try await rest.deleteEvent(eventID, in: guildID)
            events = .loaded((events.value ?? []).filter { $0.id != eventID })
        }
    }

    /// Keeps the two fields the write routes do not answer with.
    ///
    /// `interestedCount` comes from a separate route and `isInterested` from a
    /// third; an edit response carries neither, and replacing the row wholesale
    /// would blank both every time somebody renamed an event.
    private func replaceEvent(_ updated: ScheduledEvent) {
        var current = events.value ?? []
        guard let index = current.firstIndex(where: { $0.id == updated.id }) else {
            current.append(updated)
            events = .loaded(current)
            return
        }
        var merged = updated
        merged.interestedCount = updated.interestedCount ?? current[index].interestedCount
        merged.isInterested = current[index].isInterested
        current[index] = merged
        events = .loaded(current)
    }

    /// An invite code for a channel, for the event share link.
    ///
    /// Not banner-ed through `perform`: copying a link is not a save, and a
    /// "Saved" tick for it would be the window reporting something that did not
    /// happen.
    func inviteCode(in channelID: ChannelID) async -> String? {
        try? await rest.createInvite(in: channelID)?.id
    }

    // MARK: Games

    /// Names and covers for the ids a profile stores.
    ///
    /// Memoized across the window's life: the ids change only when somebody
    /// edits them, and re-resolving four games through a route that answers
    /// 128 KB for forty of them on every page visit is the wrong trade.
    func resolveGames(_ ids: [ApplicationID]) async throws -> [GameSummary] {
        let missing = ids.filter { gameCache[$0] == nil }
        if !missing.isEmpty {
            for game in try await rest.gameSummaries(ids: missing) { gameCache[game.id] = game }
        }
        // In the profile's own order, which is the order the page draws them.
        return ids.compactMap { gameCache[$0] }
    }

    func searchGames(_ query: String) async throws -> [GameSummary] {
        let results = try await rest.searchGames(query)
        // A search result is a resolved game, so it primes the cache the picker
        // will need a moment later when it is chosen.
        for game in results { gameCache[game.id] = game }
        return results
    }

    // MARK: - Helpers

    /// Channels a message can be sent in, for the pickers that want one.
    var textChannels: [ChannelSummary] {
        channels.filter { $0.kind == .text || $0.kind == .announcement }
    }

    var voiceChannels: [ChannelSummary] {
        channels.filter { $0.kind == .voice }
    }

    func channelName(_ id: ChannelID?) -> String? {
        guard let id else { return nil }
        return channels.first { $0.id == id }?.name
    }

    /// What a failure says on a page.
    ///
    /// Discord's own message wherever there is one — "Missing Permissions" is
    /// far more use than "the request failed" — and a plain sentence otherwise.
    static func describe(_ error: Error) -> String {
        switch error {
        case DiscordREST.Failure.unauthorized:
            "Your session has expired."
        case DiscordREST.Failure.forbidden:
            "You do not have permission to do that here."
        case DiscordREST.Failure.notFound:
            "This server has not set that up."
        case DiscordREST.Failure.api(_, _, let message):
            message ?? "Discord refused that."
        case DiscordREST.Failure.transport:
            "Could not reach Discord."
        case DiscordREST.Failure.decoding:
            "Discord answered with something this client could not read."
        default:
            (error as NSError).localizedDescription
        }
    }

    private static func trace(_ message: @autoclosure () -> String) {
        DiagnosticLog.trace("serverSettings", message())
    }
}
