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
    /// A channel's own invites and webhooks — its settings' Invites and
    /// Integrations pages. Separate from the server's lists, which need Manage
    /// Server where these need only Manage Channel.
    /// The channel whose own settings are open on the Channels page — set
    /// from that page, or by the main window's Edit Channel.
    var openChannelID: ChannelID?
    var channelInviteTable: [ChannelID: Loadable<[GuildInvite]>] = [:]
    var channelWebhookTable: [ChannelID: Loadable<[GuildWebhook]>] = [:]
    var bans: Loadable<[GuildBan]> = .idle
    var integrations: Loadable<[GuildIntegration]> = .idle
    var webhooks: Loadable<[GuildWebhook]> = .idle
    var template: Loadable<GuildTemplate?> = .idle
    var autoModRules: Loadable<[AutoModRule]> = .idle
    var auditLog: Loadable<AuditLogPage> = .idle
    var joinForm: Loadable<JoinApplicationForm> = .idle
    var discoveryRequirements: Loadable<DiscoveryRequirements> = .idle
    var widget: Loadable<GuildWidgetSettings> = .idle
    var vanity: Loadable<VanityURL> = .idle
    /// Where a refused write is told, outside this window — an editor the main
    /// window raises has no toolbar to carry `save`.
    var reportFailure: ((String) -> Void)?
    var onboarding: Loadable<GuildOnboarding> = .idle
    var voiceRegions: Loadable<[VoiceRegion]> = .idle
    var serverGuide: Loadable<ServerGuide> = .idle
    /// A Community server's Welcome Screen — asked when the window opens, as
    /// Discord's is, because its answer is what offers the row.
    var welcomeScreen: Loadable<WelcomeScreen> = .idle

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
    private var channelSettingsTask: Task<Void, Never>?
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
        case .serverTheme:
            // The theme itself is the resident server's; the guild is what
            // says the server may wear one.
            await loadGuild()
        case .engagement:
            await loadGuild()
            await loadWidget()
        case .boostPerks:
            await loadGuild()
            // The Custom Invite Link is an administrator's section, and only
            // a server with the perk answers the route.
            if permissions.contains(.administrator), let settings = settings.value,
               BoostTier.unlocks(.vanityURL, features: settings.features, premiumTier: settings.premiumTier)
            {
                await fill(\.vanity) { [rest, guildID] in try await rest.vanityURL(of: guildID) }
            }
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
            // Apply from Profile is the profile's visibility.
            await loadProfile()
        case .integrations:
            // Webhooks and followed channels are two rows on this page, and a
            // Twitch or YouTube sync names the role it grants.
            await loadIntegrations()
            await loadWebhooks()
            await loadRoles()
        case .safety:
            await loadGuild()
            await loadAutoModRules()
        case .auditLog:
            await loadAuditLog()
        case .bans:
            await loadBans()
        case .community:
            await loadGuild()
            // Enable Community's last step can clear @everyone's risky
            // permissions, which is a write of that role.
            await loadRoles()
        case .onboarding:
            // The Server Guide is a row on this page.
            await loadOnboarding()
            await loadServerGuide()
        case .template:
            await loadTemplate()
        case .welcomeScreen:
            await loadWelcomeScreen()
        case .insights, .members, .appDirectory, .deleteServer:
            // Server Insights lives on Discord's website; the other three act
            // rather than open a page.
            break
        }
    }

    /// What a channel's own settings need beyond the resident channel: the
    /// delete gate's two inputs — a guide task or a default channel is what
    /// makes a channel undeletable, and neither is knowable from the channel —
    /// and the server's level and features, which set the Overview's bitrate
    /// ceiling and its summaries switch.
    func loadChannelSettings() {
        guard channelSettingsTask == nil else { return }
        channelSettingsTask = Task { [weak self] in
            await self?.loadServerGuide()
            await self?.loadOnboarding()
            await self?.loadGuild()
            self?.channelSettingsTask = nil
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
            Self.trace("audit log page failed: \(error)")
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
            let message = Self.describe(error)
            save = .failed(message)
            reportFailure?(message)
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

    /// Boost Perks' writes: the progress bar, the banner, the invite
    /// background — each only when it changed.
    func saveBoostPerks(
        progressBar: Bool? = nil,
        banner: ImageData?? = nil,
        splash: ImageData?? = nil
    ) async {
        await perform { [self] in
            settings = .loaded(try await rest.updateBoostPerks(
                in: guildID,
                progressBar: progressBar,
                banner: banner,
                splash: splash
            ))
        }
    }

    /// Sets the Custom Invite Link; an empty code removes it.
    func saveVanityURL(_ code: String) async {
        await perform { [self] in
            vanity = .loaded(try await rest.setVanityURL(code, in: guildID))
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
            if let list = channelInviteTable[channelID]?.value {
                channelInviteTable[channelID] = .loaded([invite] + list)
            }
        }
    }

    func deleteInvite(_ code: String) async {
        await perform { [self] in
            try await rest.deleteInvite(code)
            invites = .loaded((invites.value ?? []).filter { $0.id != code })
            for (channelID, table) in channelInviteTable {
                if let list = table.value { channelInviteTable[channelID] = .loaded(list.filter { $0.id != code }) }
            }
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

    /// Turns on a Twitch or YouTube sync for one of the reader's accounts,
    /// then reads the list back — the route answers with nothing to merge.
    func enableIntegration(type: String, accountID: String) async {
        await perform { [self] in
            try await rest.enableIntegration(type: type, accountID: accountID, in: guildID)
            integrations = .loaded(try await rest.guildIntegrations(in: guildID))
        }
    }

    /// Saves a sync's expiry settings and keeps the list in step.
    func updateIntegration(_ id: UInt64, expiry: GuildIntegration.Expiry) async {
        await perform { [self] in
            try await rest.updateIntegration(id, in: guildID, expiry: expiry)
            integrations = .loaded((integrations.value ?? []).map { integration in
                guard integration.id == id else { return integration }
                var updated = integration
                updated.expiry = expiry
                return updated
            })
        }
    }

    func syncIntegration(_ id: UInt64) async {
        await perform { [self] in
            try await rest.syncIntegration(id, in: guildID)
        }
    }

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
            if let list = channelWebhookTable[channelID]?.value {
                channelWebhookTable[channelID] = .loaded(list + [webhook])
            }
        }
    }

    func saveWebhook(_ id: UInt64, name: String, channelID: ChannelID?, avatar: ImageData?? = nil) async {
        await perform { [self] in
            guard var updated = try await rest.updateWebhook(
                id, name: name, channelID: channelID, avatar: avatar
            ) else { return }
            // The update response drops the token. Keeping the row's own
            // means Copy Webhook URL still works after a rename.
            let known = (webhooks.value ?? []) + channelWebhookTable.values.flatMap { $0.value ?? [] }
            if updated.token == nil { updated.token = known.first { $0.id == id }?.token }
            if var current = webhooks.value, let index = current.firstIndex(where: { $0.id == id }) {
                current[index] = updated
                webhooks = .loaded(current)
            }
            // A webhook moved to another channel leaves one table and joins the other.
            for (key, table) in channelWebhookTable {
                guard var list = table.value else { continue }
                list.removeAll { $0.id == id }
                if key == updated.channelID { list.append(updated) }
                channelWebhookTable[key] = .loaded(list)
            }
        }
    }

    func deleteWebhook(_ id: UInt64) async {
        await perform { [self] in
            try await rest.deleteWebhook(id)
            webhooks = .loaded((webhooks.value ?? []).filter { $0.id != id })
            for (key, table) in channelWebhookTable {
                if let list = table.value { channelWebhookTable[key] = .loaded(list.filter { $0.id != id }) }
            }
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

    // MARK: The server's theme

    /// Saves a theme — Discord's settings save, one `PATCH` of the theme and
    /// its switch. The `GUILD_UPDATE` that follows is what dresses the window.
    func saveServerTheme(_ theme: GuildTheme) async -> GuildTheme? {
        var saved: GuildTheme?
        _ = await perform { [self] in
            saved = try await rest.updateServerTheme(theme, in: guildID)
        }
        return saved
    }

    // MARK: The Welcome Screen

    /// Asked only of a Community server — Discord's settings ask it beside
    /// onboarding when the window opens on one, and no other server has one.
    private func loadWelcomeScreen() async {
        await loadGuild()
        guard settings.value?.isCommunity == true else { return }
        await fill(\.welcomeScreen) { [rest, guildID] in try await rest.welcomeScreen(of: guildID) }
    }

    /// Whether it is on — the server's feature, not the route's answer.
    var isWelcomeScreenEnabled: Bool {
        settings.value?.features.contains(WelcomeScreen.enabledFeature) ?? false
    }

    /// Discord's Disable — the switch only goes this way now.
    func disableWelcomeScreen() async {
        await perform { [self] in
            welcomeScreen = .loaded(try await rest.disableWelcomeScreen(in: guildID))
            dropWelcomeScreenFeature()
        }
    }

    /// Saves the channels after one was moved or taken out. The last one out
    /// turns the screen off with it, as Discord's page does.
    func saveWelcomeChannels(_ channels: [WelcomeScreen.Channel]) async {
        let disables = channels.isEmpty && isWelcomeScreenEnabled
        await perform { [self] in
            welcomeScreen = .loaded(try await rest.setWelcomeChannels(channels, in: guildID, disables: disables))
            if disables { dropWelcomeScreenFeature() }
        }
    }

    /// The feature leaves the server with the write; the `GUILD_UPDATE` that
    /// says so reaches the main window, not this table.
    private func dropWelcomeScreenFeature() {
        guard var current = settings.value else { return }
        current.features.remove(WelcomeScreen.enabledFeature)
        settings = .loaded(current)
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

    /// Clears Discord's risky permissions from `@everyone` — one write of the
    /// role's permissions alone, as Discord's own button sends it.
    func removeRiskyPermissions() async {
        await perform { [self] in
            guard var current = roles.value,
                  let index = current.firstIndex(where: { $0.id.rawValue == guildID.rawValue })
            else { return }
            let reduced = current[index].permissions.subtracting(.risky)
            current[index] = try await rest.updateRolePermissions(
                current[index].id, in: guildID, permissions: reduced
            )
            roles = .loaded(current)
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

    /// Adds and removes features in one write — the Activity Feed's switch
    /// sets one of a pair and clears the other, as Discord's does.
    func setFeatures(adding added: Set<String>, removing removed: Set<String>) async {
        await perform { [self] in
            guard let current = settings.value else { return }
            settings = .loaded(try await rest.setGuildFeatures(
                in: guildID, features: current.features.subtracting(removed).union(added)
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

    /// The Private Channel switch — Discord's `uB` and `tP` (`495273`).
    ///
    /// **`@everyone`'s overwrite is edited, not replaced**: only the access bits
    /// move, so a read-only channel stays read-only. Going private, a reader
    /// who is not an administrator is given access of their own first, as
    /// Discord gives it, so the switch cannot lock out the person flipping it.
    func setChannelPrivate(_ channel: Channel, isPrivate: Bool, keepingAccessFor readerID: UserID?) async {
        await perform { [self] in
            let access = ChannelAccess.permissions(for: channel.kind)
            if isPrivate, let readerID {
                var mine = channel.overwrites.first { $0.id == readerID.rawValue }
                    ?? PermissionOverwrite(id: readerID.rawValue, subject: .member, allow: [], deny: [])
                mine.allow.formUnion(access)
                mine.deny.subtract(access)
                try await rest.setChannelOverwrite(
                    in: channel.id, subjectID: mine.id, isRole: false, allow: mine.allow, deny: mine.deny
                )
            }
            let everyone = ChannelAccess.everyoneOverwrite(for: channel, guildID: guildID, makingPrivate: isPrivate)
            try await rest.setChannelOverwrite(
                in: channel.id, subjectID: everyone.id, isRole: true, allow: everyone.allow, deny: everyone.deny
            )
            if let index = channels.firstIndex(where: { $0.id == channel.id }) {
                channels[index].isPublic = !isPrivate
            }
        }
    }

    /// Writes one role's or member's overwrite, or removes it when it is
    /// empty — an overwrite that grants and denies nothing is noise in the list.
    func saveOverwrite(_ overwrite: PermissionOverwrite, in channelID: ChannelID) async {
        await perform { [self] in
            if overwrite.allow.isEmpty && overwrite.deny.isEmpty && overwrite.id != guildID.rawValue {
                try await rest.deleteChannelOverwrite(in: channelID, subjectID: overwrite.id)
            } else {
                try await rest.setChannelOverwrite(
                    in: channelID,
                    subjectID: overwrite.id,
                    isRole: overwrite.subject == .role,
                    allow: overwrite.allow,
                    deny: overwrite.deny
                )
            }
        }
    }

    /// "Delete Permission Settings": one role or member off the channel.
    func removeOverwrite(_ subjectID: UInt64, in channelID: ChannelID) async {
        await perform { [self] in
            try await rest.deleteChannelOverwrite(in: channelID, subjectID: subjectID)
        }
    }

    /// Sync Now: the channel's permissions become its category's.
    func syncWithCategory(_ channelID: ChannelID, overwrites: [PermissionOverwrite]) async {
        await perform { [self] in
            try await rest.setChannelOverwrites(overwrites, of: channelID)
        }
    }

    // MARK: A channel's invites and webhooks

    /// One channel's invites, asked for when its Invites page opens.
    func loadChannelInvites(_ channelID: ChannelID) async {
        guard (channelInviteTable[channelID] ?? .idle).wantsFetch else { return }
        channelInviteTable[channelID] = .loading
        do {
            channelInviteTable[channelID] = .loaded(try await rest.channelInvites(in: channelID))
        } catch {
            channelInviteTable[channelID] = .failed(Self.describe(error))
        }
    }

    func revokeChannelInvite(_ code: String, in channelID: ChannelID) async {
        await perform { [self] in
            try await rest.deleteInvite(code)
            if case .loaded(let list) = channelInviteTable[channelID] ?? .idle {
                channelInviteTable[channelID] = .loaded(list.filter { $0.id != code })
            }
            invites = .idle
        }
    }

    func loadChannelWebhooks(_ channelID: ChannelID) async {
        guard (channelWebhookTable[channelID] ?? .idle).wantsFetch else { return }
        channelWebhookTable[channelID] = .loading
        do {
            channelWebhookTable[channelID] = .loaded(try await rest.channelWebhooks(in: channelID))
        } catch {
            channelWebhookTable[channelID] = .failed(Self.describe(error))
        }
    }

    func saveChannel(_ overview: ChannelOverview) async {
        await perform { [self] in
            guard let updated = try await rest.updateChannel(overview) else { return }
            if let index = channels.firstIndex(where: { $0.id == overview.id }) {
                channels[index].name = updated.name
                channels[index].kind = updated.kind
            }
        }
    }

    /// The regions a voice channel may be pinned to. Asked for when a voice
    /// channel's Overview opens, once per window.
    func loadVoiceRegions() async {
        await fill(\.voiceRegions) { [rest, guildID] in try await rest.voiceRegions(in: guildID) }
    }

    /// The server's voice bitrate ceiling, from its level and features.
    var maximumBitrate: Int {
        let settings = self.settings.value
        return BoostTier.maximumBitrate(
            premiumTier: settings?.premiumTier ?? 0,
            features: settings?.features ?? []
        )
    }

    /// Whether the server takes channel summaries at all — the two feature
    /// strings the reader's own summaries are gated on.
    var offersSummaries: Bool {
        let features = settings.value?.features ?? []
        return AppModel.summaryFeatures.contains { features.contains($0) }
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
        let settings = settings.value
        return ChannelDeleteGate.refusal(
            for: channelID,
            guide: serverGuide.value,
            onboarding: onboarding.value,
            chattableDefaults: (onboarding.value?.defaultChannelIDs ?? [])
                .filter { id in channels.first { $0.id == id }?.isPublic ?? false }
                .count,
            community: settings.flatMap {
                $0.isCommunity ? ($0.rulesChannelID, $0.publicUpdatesChannelID) : nil
            }
        )
    }

    // MARK: Events
    //
    // Created and edited from the server's events in the main window
    // (`EventEditorHost`); the gateway's `GUILD_SCHEDULED_EVENT_CREATE` and
    // `…_UPDATE` are what put the result on screen.

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
            _ = try await rest.createEvent(
                in: guildID,
                name: name,
                description: description,
                location: location,
                startsAt: startsAt,
                endsAt: endsAt,
                recurrence: recurrence,
                cover: cover
            )
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
            _ = try await rest.updateEvent(
                eventID,
                in: guildID,
                name: name,
                description: description,
                location: location,
                startsAt: startsAt,
                endsAt: endsAt,
                recurrence: recurrence,
                cover: cover
            )
        }
    }

    // MARK: Deleting the server

    /// Discord's `deleteGuild`: `POST /guilds/{id}/delete`, owner only.
    ///
    /// Returns what to say when it is refused — an account with two-factor on
    /// is asked for a code this client cannot yet collect, and the refusal is
    /// Discord's own sentence.
    func deleteServer() async -> String? {
        do {
            try await rest.deleteGuild(guildID)
            return nil
        } catch {
            return Self.describe(error)
        }
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
    /// What to say about a refused read or write: Discord's own sentence
    /// where the API sent one, and its generic line otherwise — never one this
    /// client wrote.
    static func describe(_ error: Error) -> String {
        switch error {
        case DiscordREST.Failure.api(_, _, let message?) where !message.isEmpty:
            message
        default:
            "Oops, something went wrong..."
        }
    }

    private static func trace(_ message: @autoclosure () -> String) {
        DiagnosticLog.trace("serverSettings", message())
    }
}
