import AppKit
import SwiftUI
import WingcordCore

/// Pick one channel and confirm — the template flow.
struct ChannelPickerSheet: View {
    var title: String
    var confirmTitle: String
    var channels: [ServerSettingsStore.ChannelSummary]
    var commit: (ChannelID) -> Void

    @State private var channelID: ChannelID?

    var body: some View {
        SheetFrame(title: title, confirmTitle: confirmTitle, canConfirm: channelID != nil) {
            guard let channelID else { return }
            commit(channelID)
        } content: {
            SheetField(title: "Channel", isRequired: true) {
                Picker("", selection: $channelID) {
                    Text("Select a Channel").tag(ChannelID?.none)
                    ForEach(channels) { channel in
                        Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                    }
                }
                .labelsHidden()
            }
        }
        .task { if channelID == nil { channelID = channels.first?.id } }
    }
}

// MARK: - Safety Setup

/// The levels every server has, and the AutoMod rules it has made.
///
/// Rules can now be built, edited and deleted — see `AutoModSheet`, which reads
/// the four trigger-dependent constraints off `AutoModRule.Trigger` rather than
/// re-deriving them.
///
/// **The enable/disable switch is still the one route here nobody has watched.**
/// The create is captured; `PATCH /auto-moderation/rules/{id}` is not.
struct SafetyPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var editing: AutoModRule?
    @State private var creating = false
    @State private var deleting: AutoModRule?
    @State private var isRemovingRisky = false
    @State private var page = Page.overview

    /// Discord's Safety Setup pages (`uS.C`).
    enum Page: Hashable {
        case overview
        case raidProtection
        case dmAndSpam
        case autoMod
        case permissions
    }

    /// Discord's Safety Setup (`uB`): on a Community server, an overview of
    /// four rows — Raid Protection and CAPTCHA, DM and Spam Protection,
    /// AutoMod, Permissions — each "N of M enabled" with Edit, opening its own
    /// page. The always-on rows are Discord's statements rather than settings —
    /// drawn as it draws them, a switch that is on and cannot move, with "This
    /// feature is on by default" — and only on a Community server, which is the
    /// only kind Discord shows them on. A server that is not one gets Discord's
    /// older single page: its levels, AutoMod and permissions.
    var body: some View {
        LoadableContent(store.settings) { settings in
            if settings.isCommunity {
                switch page {
                case .overview: overview(settings)
                case .raidProtection: subpage("Raid Protection and CAPTCHA") { raidProtection(settings) }
                case .dmAndSpam: subpage("DM and Spam Protection") { dmAndSpam(settings) }
                case .autoMod: subpage("AutoMod") { autoMod }
                case .permissions: subpage("Permissions") { permissions(settings) }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    dmAndSpam(settings)
                    autoMod
                    permissions(settings)
                }
            }
        }
        .task { store.load(.roles) }
    }

    // MARK: Overview

    private func overview(_ settings: GuildSettings) -> some View {
        let everyone = store.roles.value?.first { $0.id.rawValue == store.guildID.rawValue }
        return SettingsGroup {
            SettingsCard {
                overviewRow(
                    "Raid Protection and CAPTCHA",
                    count: SafetyCounts.raidProtection(features: settings.features),
                    symbolName: "shield.lefthalf.filled",
                    page: .raidProtection
                )
                CardDivider()
                overviewRow(
                    "DM and Spam Protection",
                    count: SafetyCounts.dmAndSpam,
                    symbolName: "envelope.badge.shield.half.filled",
                    page: .dmAndSpam
                )
                CardDivider()
                overviewRow(
                    "AutoMod",
                    count: SafetyCounts.autoMod(store.autoModRules.value ?? []),
                    symbolName: "wand.and.stars",
                    page: .autoMod
                )
                CardDivider()
                overviewRow(
                    "Permissions",
                    count: SafetyCounts.permissions(
                        mfaLevel: settings.mfaLevel,
                        features: settings.features,
                        everyonePermissions: everyone?.permissions
                    ),
                    symbolName: "key.fill",
                    page: .permissions
                )
            }
        }
    }

    private func overviewRow(
        _ title: String,
        count: (enabled: Int, total: Int),
        symbolName: String,
        page target: Page
    ) -> some View {
        DescribedRow(title, detail: Text(SafetyCounts.sentence(count))) {
            Image(symbol: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.pink.gradient, in: .circle)
                .accessibilityHidden(true)
        } trailing: {
            Button("Edit") { page = target }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }

    /// A page inside Safety Setup — Discord's Back above its title.
    private func subpage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Button { page = .overview } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(SettingsType.controlLabel)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            Text(verbatim: title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
            content()
        }
    }

    /// A section's own heading on the single page; none inside a sub-page,
    /// which carries it already.
    private func sectionTitle(_ title: String) -> String? {
        store.settings.value?.isCommunity == true ? nil : title
    }

    // MARK: Raid protection

    private func raidProtection(_ settings: GuildSettings) -> some View {
        SettingsGroup(sectionTitle("Raid Protection and CAPTCHA")) {
            SettingsCard {
                SettingsToggle(
                    title: "Activity Alerts",
                    help: "Includes added protection from join raids.",
                    isOn: Binding(
                        // `RAID_ALERTS_DISABLED` is inverted — present means off.
                        get: { !settings.features.contains("RAID_ALERTS_DISABLED") },
                        set: { isOn in
                            Task { await store.setFeature("RAID_ALERTS_DISABLED", isOn: !isOn) }
                        }
                    )
                )
                CardDivider()
                AlwaysOnRow(title: "CAPTCHA suspicious accounts before they are able to join")
                CardDivider()
                AlwaysOnRow(title: "CAPTCHA all accounts before they can join during a suspected raid")
            }
        }
    }

    // MARK: DM and spam

    private func dmAndSpam(_ settings: GuildSettings) -> some View {
        SettingsGroup(sectionTitle("DM and Spam Protection")) {
            SettingsCard {
                SettingsPickerRow(
                    title: "Verification Level",
                    help: "Members of the server must meet the following criteria before they can "
                        + "send messages. If a member has an assigned role and server onboarding is "
                        + "not enabled, this does not apply.",
                    options: VerificationLevel.selectable.map { .init($0, $0.title) },
                    selection: Binding(
                        get: { settings.verificationLevel },
                        set: { level in
                            Task {
                                await store.saveModerationLevels(
                                    verification: level,
                                    explicitContent: settings.explicitContentFilter
                                )
                            }
                        }
                    )
                )
                CardDivider()
                SettingsPickerRow(
                    title: "Explicit image filter",
                    options: ExplicitContentFilter.selectable.map { .init($0, $0.title) },
                    selection: Binding(
                        get: { settings.explicitContentFilter },
                        set: { filter in
                            Task {
                                await store.saveModerationLevels(
                                    verification: settings.verificationLevel,
                                    explicitContent: filter
                                )
                            }
                        }
                    )
                )
                if settings.isCommunity {
                    CardDivider()
                    AlwaysOnRow(
                        title: "Hide DMs from suspicious users",
                        detail: "Send suspicious DMs to a separate Spam Inbox. Members can send a scam "
                            + "report or move it back to Inbox."
                    )
                    CardDivider()
                    AlwaysOnRow(
                        title: "Filter DMs from unknown users",
                        detail: "Filter DMs from unknown users to Message Requests Inbox. Members must "
                            + "approve the request before they are able to respond."
                    )
                    CardDivider()
                    AlwaysOnRow(title: "Warn members before they visit outbound links")
                    CardDivider()
                    AlwaysOnRow(title: "Hide all messages from and delete suspected spammers")
                }
            }
            SettingsFootnote(settings.verificationLevel.detail)
        }
    }

    // MARK: Permissions

    private func permissions(_ settings: GuildSettings) -> some View {
        SettingsGroup(sectionTitle("Permissions")) {
            SettingsCard {
                // Changing it takes the owner's two-factor code, which this
                // client cannot collect yet — so it says where it stands and
                // why it does not move, in Discord's words.
                DescribedRow(
                    "Require 2FA for moderator actions",
                    detail: Text("Moderators must have two-factor authentication enabled to ban, kick, or timeout members and delete messages.")
                ) {
                    Toggle("Require 2FA for moderator actions", isOn: .constant(settings.mfaLevel == 1))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .disabled(true)
                        .help("This setting can only be changed by a server owner with 2FA enabled on their account.")
                }
                CardDivider()
                SettingsToggle(
                    title: "Restrict member prune to admins",
                    help: "Only administrators and the server owner can prune inactive members when "
                        + "this setting is enabled.",
                    isOn: Binding(
                        get: { settings.features.contains("PRUNE_REQUIRES_ADMIN") },
                        set: { isOn in
                            Task { await store.setFeature("PRUNE_REQUIRES_ADMIN", isOn: isOn) }
                        }
                    )
                )
                CardDivider()
                riskyPermissions
            }
        }
    }

    /// Discord's "Remove risky permissions from @everyone": a count, and one
    /// write that clears them — refused, as Discord refuses it, where it would
    /// take a permission away from the reader themselves.
    @ViewBuilder
    private var riskyPermissions: some View {
        let everyone = store.roles.value?.first { $0.id.rawValue == store.guildID.rawValue }
        let risky = everyone.map { $0.permissions.intersection(.risky) } ?? []
        let count = risky.rawValue.nonzeroBitCount
        let refusal = revokesOwnPermission(risky)
        SettingsControlRow(
            "Remove risky permissions from @everyone",
            help: count == 0
                ? "All risky permissions disabled!"
                : "@everyone currently has \(count) risky permissions enabled"
        ) {
            if count == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.affirmative)
                    .accessibilityLabel(Text("Item completed"))
            } else {
                Button(isRemovingRisky ? "Disabling risky permissions..." : "Remove risky permissions") {
                    isRemovingRisky = true
                    Task {
                        await store.removeRiskyPermissions()
                        isRemovingRisky = false
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isRemovingRisky || refusal)
                .help(refusal
                    ? "Cannot disable risky permissions because this would revoke your own permissions."
                    : "")
            }
        }
    }

    /// Whether clearing these from `@everyone` would leave the reader without
    /// one of them — Discord's check: every risky bit must still come from one
    /// of the reader's other roles, unless they own the server or administer it
    /// through another role.
    private func revokesOwnPermission(_ risky: Permissions) -> Bool {
        guard !risky.isEmpty, let me = model.currentUserID else { return false }
        if model.guilds[store.guildID]?.ownerID == me { return false }
        let roles = store.roles.value ?? []
        let mine = Set(model.members[store.guildID]?[me]?.roleIDs ?? [])
        let granted = roles
            .filter { mine.contains($0.id) && $0.id.rawValue != store.guildID.rawValue }
            .reduce(into: Permissions()) { $0.formUnion($1.permissions) }
        if granted.contains(.administrator) { return false }
        return !granted.isSuperset(of: risky)
    }

    private var autoMod: some View {
        SettingsGroup(sectionTitle("AutoMod")) {
            SettingsCard {
                DescribedRow(
                    "AutoMod",
                    detail: Text("Give your mods a break while keeping your server safe! Set up filters to moderate content and automate a custom response when they\u{2019}re found, and AutoMod will make it happen.")
                ) {
                    Button("Create") { creating = true }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .padding(.bottom, Spacing.base)

            LoadableContent(
                store.autoModRules,
                isEmpty: \.isEmpty,
                empty: { EmptyView() }
            ) { rules in
                SettingsCard {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { CardDivider() }
                        ruleRow(rule)
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            AutoModSheet(existing: nil, store: store) { draft, existing in
                Task { await store.saveAutoModRule(draft, existing: existing) }
            }
        }
        .sheet(item: $editing) { rule in
            AutoModSheet(existing: rule, store: store) { draft, existing in
                Task { await store.saveAutoModRule(draft, existing: existing) }
            }
        }
    }

    private func ruleRow(_ rule: AutoModRule) -> some View {
        ObjectRow(
            title: rule.name,
            subtitle: ruleHelp(rule)
        ) {
            SettingsIconTile(
                symbolName: "exclamationmark.shield.fill",
                tint: rule.isEnabled ? .pink : .gray,
                side: SettingsMetrics.navigationIconSide,
                radius: SettingsMetrics.navigationIconRadius
            )
        } trailing: {
            HStack(spacing: Spacing.tight) {
                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { isOn in
                        Task { await store.setAutoModRuleEnabled(rule.id, isEnabled: isOn) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(SettingsSurface.switchOn)

                // **A rule this client cannot express is shown and left alone.**
                // Editing it would mean saving the parts this build cannot draw
                // as whatever the encoder defaulted to — see
                // `AutoModDraft.isEditable`.
                if AutoModDraft.isEditable(rule) {
                    RowIconButton(symbolName: "pencil", label: "Edit \(rule.name)") {
                        editing = rule
                    }
                }
                RowIconButton(
                    symbolName: "trash",
                    label: "Delete \(rule.name)",
                    role: .destructive
                ) {
                    deleting = rule
                }
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { deleting?.id == rule.id },
                set: { if !$0 { deleting = nil } }
            ),
            title: rule.name,
            message: Self.triggerLine(rule.trigger),
            confirmTitle: "Delete"
        ) {
            Task { await store.deleteAutoModRule(rule.id) }
        }
    }

    private func ruleHelp(_ rule: AutoModRule) -> String {
        Self.triggerLine(rule.trigger)
    }

    /// Discord's line for each kind of rule, from its AutoMod page.
    static func triggerLine(_ trigger: AutoModRule.Trigger) -> String {
        switch trigger {
        case .keyword: "Create your own filter to block specific language from your server."
        case .spam: "Monitor messages, Forum posts, and threads for potentially spammy content or activity. (Support for English only)"
        case .keywordPreset: "Flag messages that contain profanity and more. (Support for English only)"
        case .mentionSpam: "Block messages with an excessive # of role and user mentions"
        case .userProfile: "Block specific language in your member\u{2019}s usernames."
        case .guildPolicy: "The app chooses what action to take for each message, including blocking the message or doing nothing at all."
        case .unrecognised: ""
        }
    }
}

// MARK: - Audit Log

/// Who did what.
///
/// **The entry does not carry the objects it names** — `user_id` is a snowflake
/// and the users are in a sibling array — so the page reads names out of the
/// page's own side tables rather than off the row. See `AuditLogPage`.
/// One of Discord's always-on safety statements: a switch that is on and
/// cannot move, with its reason on hover — "This feature is on by default".
private struct AlwaysOnRow: View {
    var title: String
    var detail: String?

    var body: some View {
        SettingsControlRow(title, help: detail) {
            Toggle(title, isOn: .constant(true))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(true)
                .help("This feature is on by default")
        }
    }
}

struct AuditLogPane: View {
    let store: ServerSettingsStore

    @State private var isLoadingMore = false

    var body: some View {
        LoadableContent(
            store.auditLog,
            isEmpty: { $0.entries.isEmpty },
            empty: {
                EmptyRow(message: "No Logs Yet — Once moderators begin moderating, you can moderate the moderation here.", symbolName: "list.bullet.rectangle")
            }
        ) { page in
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup {
                    SettingsCard {
                        ForEach(Array(page.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { CardDivider() }
                            row(entry, page: page)
                        }
                    }
                }

                // Fifty at a time. The button rather than infinite scroll: this
                // is a log somebody reads to answer a question, not a feed.
                HStack {
                    Spacer()
                    Button {
                        Task {
                            isLoadingMore = true
                            await store.loadMoreAuditLog()
                            isLoadingMore = false
                        }
                    } label: {
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load More")
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(isLoadingMore)
                    Spacer()
                }
                .padding(.top, Spacing.margin)
            }
        }
    }

    private func row(_ entry: AuditLogEntry, page: AuditLogPage) -> some View {
        ObjectRow(
            title: title(entry, page: page),
            subtitle: subtitle(entry),
            badge: entry.timestamp.formatted(.relative(presentation: .named))
        ) {
            SettingsIconTile(
                symbolName: entry.action.symbolName,
                tint: tint(entry.action),
                side: SettingsMetrics.navigationIconSide + 4,
                radius: SettingsMetrics.sidebarIconRadius
            )
        }
    }

    private func title(_ entry: AuditLogEntry, page: AuditLogPage) -> String {
        let actor = entry.userID
            .flatMap { page.users[$0]?.name }
            ?? "Discord"
        return "\(actor) \(entry.action.sentence)"
    }

    /// What changed, in as many fields as fit on one line.
    ///
    /// Capped at three: a guild update touches a dozen fields and a row that
    /// listed all of them would be a paragraph. The reason, where somebody gave
    /// one, comes first — it is the only free text in the whole log.
    private func subtitle(_ entry: AuditLogEntry) -> String? {
        var parts: [String] = []
        if let reason = entry.reason { parts.append("“\(reason)”") }
        let changes = entry.changes.prefix(3).map { change -> String in
            switch (change.before, change.after) {
            case (let before?, let after?): "\(change.title): \(before) → \(after)"
            case (nil, let after?): "\(change.title): \(after)"
            case (let before?, nil): "\(change.title) was \(before)"
            case (nil, nil): change.title
            }
        }
        parts.append(contentsOf: changes)
        if entry.changes.count > 3 { parts.append("and \(entry.changes.count - 3) more") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func tint(_ action: AuditLogAction) -> Color {
        if action.isDestructive { return Palette.destructive }
        if action.isCreation { return Palette.affirmative }
        return .gray
    }
}
