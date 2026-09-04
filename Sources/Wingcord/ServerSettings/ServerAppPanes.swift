import AppKit
import SwiftUI
import WingcordCore

// MARK: - Integrations
//
// **One route answers for three unrelated things**, and the page draws them as
// three sections because that is what they are: apps somebody added, subscriber
// syncs on Twitch and YouTube, and — from a different route entirely — the
// webhooks and followed channels, which get their own page.

struct IntegrationsPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var removing: GuildIntegration?

    var body: some View {
        LoadableContent(
            store.integrations,
            isEmpty: \.isEmpty,
            empty: {
                EmptyRow(
                    message: "Nothing is connected to this server.",
                    symbolName: "puzzlepiece.extension"
                )
            }
        ) { integrations in
            let apps = integrations.filter { $0.kind == .discord }
            let syncs = integrations.filter { $0.kind != .discord }

            VStack(alignment: .leading, spacing: 0) {
                section("Apps and bots — \(apps.count)", integrations: apps)
                section("Connected accounts — \(syncs.count)", integrations: syncs)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, integrations: [GuildIntegration]) -> some View {
        if !integrations.isEmpty {
            SettingsGroup(title) {
                SettingsCard {
                    ForEach(Array(integrations.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { CardDivider() }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ integration: GuildIntegration) -> some View {
        ObjectRow(
            title: integration.name,
            subtitle: subtitle(integration),
            badge: integration.kind == .discord ? nil : integration.kind.title
        ) {
            RemoteImage(url: integration.application?.iconURL, side: 28) {
                SettingsSurface.controlTrough.overlay {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(.rect(cornerRadius: 7, style: .continuous))
        } trailing: {
            RowIconButton(
                symbolName: "trash",
                label: "Remove \(integration.name)",
                role: .destructive
            ) {
                removing = integration
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { removing?.id == integration.id },
                set: { if !$0 { removing = nil } }
            ),
            title: "Remove \(integration.name)?",
            message: removalMessage(integration),
            confirmTitle: "Remove"
        ) {
            Task { await store.deleteIntegration(integration.id) }
        }
    }

    private func subtitle(_ integration: GuildIntegration) -> String? {
        var parts: [String] = []
        if let installer = integration.installerID, let user = model.users[installer] {
            parts.append("Added by \(user.preferredName)")
        }
        parts.append(integration.addedAt.formatted(date: .abbreviated, time: .omitted))
        if let account = integration.accountName { parts.append(account) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func removalMessage(_ integration: GuildIntegration) -> String {
        switch integration.kind {
        case .discord:
            "Its commands stop working here, and any role it manages is removed."
        case .twitch, .youtube:
            "Subscribers stop being given the role this sync grants."
        default:
            "This removes it from the server."
        }
    }
}

// MARK: - Webhooks
//
// Two kinds behind one route, and the difference decides what a row may offer.
// An **incoming** webhook has a URL somebody pastes into another service; a
// **channel follower** is the far end of a Follow on somebody else's
// announcement channel, has no URL, and has its name and avatar rewritten by
// Discord on every sync — so renaming it is a control that reverts itself.

struct WebhooksPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var isCreating = false
    @State private var renaming: UInt64?
    @State private var deleting: GuildWebhook?
    @State private var copied: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    SettingsActionRow(
                        "Create a webhook",
                        help: "A URL another service can post to, as a named sender in one channel.",
                        actionTitle: "Create"
                    ) {
                        isCreating = true
                    }
                }
            }

            LoadableContent(
                store.webhooks,
                isEmpty: \.isEmpty,
                empty: {
                    EmptyRow(
                        message: "No webhooks and no followed channels.",
                        symbolName: "arrow.triangle.branch"
                    )
                }
            ) { webhooks in
                let incoming = webhooks.filter { $0.kind == .incoming }
                let followers = webhooks.filter { $0.kind == .channelFollower }
                section("Webhooks — \(incoming.count)", webhooks: incoming)
                section("Channels followed — \(followers.count)", webhooks: followers)
            }
        }
        .sheet(isPresented: $isCreating) {
            ChannelPickerSheet(
                title: "Create a webhook",
                confirmTitle: "Create",
                channels: store.textChannels
            ) { channelID in
                Task { await store.createWebhook(in: channelID) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, webhooks: [GuildWebhook]) -> some View {
        if !webhooks.isEmpty {
            SettingsGroup(title) {
                SettingsCard {
                    ForEach(Array(webhooks.enumerated()), id: \.element.id) { index, hook in
                        if index > 0 { CardDivider() }
                        row(hook)
                    }
                }
            }
        }
    }

    private func row(_ hook: GuildWebhook) -> some View {
        ObjectRow(
            title: hook.name,
            subtitle: subtitle(hook)
        ) {
            RemoteImage(
                url: hook.avatarHash.flatMap {
                    CDN.avatar(userID: UserID(rawValue: hook.id), hash: $0, side: 28)
                },
                side: 28
            ) {
                SettingsSurface.controlTrough.overlay {
                    Image(systemName: hook.kind == .channelFollower ? "arrow.turn.down.right" : "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(.circle)
        } trailing: {
            HStack(spacing: 2) {
                // **Only an incoming webhook has a URL, and the URL is a
                // credential.** Anybody holding it can post here forever with no
                // account behind it, so it is never drawn — one deliberate press
                // puts it on the pasteboard and nothing else ever sees it.
                if hook.url != nil {
                    RowIconButton(
                        symbolName: copied == hook.id ? "checkmark" : "doc.on.doc",
                        label: "Copy webhook URL"
                    ) {
                        guard let url = hook.url else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = hook.id
                    }
                }
                if hook.isEditable {
                    RowIconButton(symbolName: "pencil", label: "Rename \(hook.name)") {
                        renaming = hook.id
                    }
                }
                RowIconButton(
                    symbolName: "trash",
                    label: "Delete \(hook.name)",
                    role: .destructive
                ) {
                    deleting = hook
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { renaming == hook.id },
            set: { if !$0 { renaming = nil } }
        )) {
            RenameSheet(title: "Rename webhook", name: hook.name) { name in
                Task { await store.saveWebhook(hook.id, name: name, channelID: hook.channelID) }
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { deleting?.id == hook.id },
                set: { if !$0 { deleting = nil } }
            ),
            title: "Delete \(hook.name)?",
            message: hook.kind == .channelFollower
                ? "This channel stops receiving that server's announcements."
                : "Anything posting through its URL stops working immediately.",
            confirmTitle: "Delete"
        ) {
            Task { await store.deleteWebhook(hook.id) }
        }
    }

    private func subtitle(_ hook: GuildWebhook) -> String? {
        var parts: [String] = []
        if let source = hook.followedSource {
            parts.append("Following \(source)")
        }
        if let name = store.channelName(hook.channelID) { parts.append("posts to #\(name)") }
        if let creator = hook.creatorID, let user = model.users[creator] {
            parts.append("by \(user.preferredName)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Pick one channel and confirm. Shared by the webhook and template flows.
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
                    Text("Choose a channel").tag(ChannelID?.none)
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
/// **Only the switch on a rule is offered, so far.** Creating one is a real
/// surface — a trigger picker, per-trigger metadata, an action list and two
/// exemption pickers — and it is not written yet. It is *buildable*: the route
/// is documented, and `…/rules/validate` checks a metadata block before it is
/// committed. The handoff carries the constraint table.
///
/// The switch itself is documentation-derived too: one AutoMod request exists
/// across five captures and it is a `GET`.
struct SafetyPane: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.settings) { settings in
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup("Verification") {
                    SettingsCard {
                        SettingsPickerRow(
                            title: "Members must",
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
                    }
                    SettingsFootnote(settings.verificationLevel.detail)
                }

                SettingsGroup("Explicit media filter") {
                    SettingsCard {
                        SettingsPickerRow(
                            title: "Scan media from",
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
                    }
                }

                autoMod
            }
        }
    }

    private var autoMod: some View {
        SettingsGroup("AutoMod") {
            LoadableContent(
                store.autoModRules,
                isEmpty: \.isEmpty,
                empty: {
                    EmptyRow(
                        message: "No AutoMod rules yet.",
                        symbolName: "exclamationmark.shield"
                    )
                }
            ) { rules in
                SettingsCard {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { CardDivider() }
                        SettingsToggle(
                            title: rule.name,
                            help: ruleHelp(rule),
                            isOn: Binding(
                                get: { rule.isEnabled },
                                set: { isOn in
                                    Task {
                                        await store.setAutoModRuleEnabled(rule.id, isEnabled: isOn)
                                    }
                                }
                            )
                        )
                    }
                }
            }
            SettingsFootnote(
                "Rules are built in Discord's own client. Wingcord can turn them "
                    + "on and off, and states what each one does."
            )
        }
    }

    private func ruleHelp(_ rule: AutoModRule) -> String {
        var parts = [rule.trigger.detail]
        if !rule.actions.isEmpty {
            parts.append(rule.actions.map(\.title).formatted(.list(type: .and)))
        }
        return parts.joined(separator: " — ")
    }
}

// MARK: - Audit Log

/// Who did what.
///
/// **The entry does not carry the objects it names** — `user_id` is a snowflake
/// and the users are in a sibling array — so the page reads names out of the
/// page's own side tables rather than off the row. See `AuditLogPage`.
struct AuditLogPane: View {
    let store: ServerSettingsStore

    @State private var isLoadingMore = false

    var body: some View {
        LoadableContent(
            store.auditLog,
            isEmpty: { $0.entries.isEmpty },
            empty: {
                EmptyRow(message: "Nothing has been recorded yet.", symbolName: "list.bullet.rectangle")
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
                            Text("Load older entries")
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
