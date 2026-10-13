import SwiftUI
import WingcordCore

// MARK: - Integrations
//
// Discord's Integrations page (`3dbf4403`): Webhooks and Channels Followed as
// two rows that open, Twitch and YouTube with their Connect buttons, then Bots
// and Apps — each app a card that opens onto its own page. Every word is
// Discord's.
//
// **One route answers for three unrelated things** — see `GuildIntegration` —
// and webhooks come from a fourth; that is why the first two rows are counts.

struct IntegrationsPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var page = Page.overview
    @State private var query = ""

    enum Page: Hashable {
        case overview
        case webhooks
        case followed
        case platform(StreamingPlatform)
        case app(UInt64)
    }

    var body: some View {
        switch page {
        case .overview:
            overview
        case .webhooks:
            subpage("Webhooks") { WebhookPage(store: store, model: model) }
        case .followed:
            subpage("Channels Followed") {
                LoadableContent(store.webhooks) { webhooks in
                    FollowedChannelsSection(store: store, webhooks: webhooks.filter { $0.kind == .channelFollower })
                }
            }
        case .platform(let platform):
            subpage(platform.title) { PlatformIntegrationPage(store: store, model: model, platform: platform) }
        case .app(let id):
            if let integration = store.integrations.value?.first(where: { $0.id == id }) {
                subpage(integration.name) {
                    AppIntegrationPage(store: store, model: model, integration: integration) {
                        page = .overview
                    }
                }
            } else {
                // Removed underneath the page.
                Color.clear.frame(height: 1).onAppear { page = .overview }
            }
        }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    SettingsNavigationRow(
                        title: "Webhooks",
                        subtitle: count(store.webhooks.value?.filter { $0.kind == .incoming }.count, one: "webhook", many: "webhooks"),
                        symbolName: "arrow.triangle.branch",
                        tint: .indigo
                    ) { page = .webhooks }
                    CardDivider()
                    SettingsNavigationRow(
                        title: "Channels Followed",
                        subtitle: count(store.webhooks.value?.filter { $0.kind == .channelFollower }.count, one: "channel", many: "channels"),
                        symbolName: "megaphone.fill",
                        tint: .indigo
                    ) { page = .followed }
                    CardDivider()
                    platformRow(.twitch)
                    CardDivider()
                    platformRow(.youtube)
                }
            }
            appsSection
        }
    }

    private func count(_ value: Int?, one: String, many: String) -> String {
        guard let value else { return "" }
        return value == 1 ? "1 \(one)" : "\(value) \(many)"
    }

    private func platformRow(_ platform: StreamingPlatform) -> some View {
        let isConnected = store.integrations.value?.contains { $0.kind == platform.kind } == true
        return DescribedRow(platform.title, detail: Text(platform.line)) {
            PlatformMark(platform: platform)
        } trailing: {
            Button(isConnected ? "Manage" : platform.connectTitle) { page = .platform(platform) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        LoadableContent(store.integrations) { integrations in
            let apps = integrations.filter { $0.kind == .discord }
            let shown = query.isEmpty
                ? apps
                : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
            SettingsGroup("Bots and Apps") {
                SettingsCard {
                    if apps.count > 6 {
                        SearchRow(query: $query, placeholder: "Search installed apps")
                        CardDivider()
                    }
                    if apps.isEmpty {
                        Text("You don't have any apps yet!")
                            .font(SettingsType.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                            .padding(SettingsMetrics.cardContentInset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if shown.isEmpty {
                        Text("No installed apps matched your search.")
                            .font(SettingsType.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                            .padding(SettingsMetrics.cardContentInset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { CardDivider() }
                        appRow(app)
                    }
                }
            }
        }
    }

    /// "Added on Nov 12, 2022 by name", the Bot and Commands chips, Manage.
    private func appRow(_ integration: GuildIntegration) -> some View {
        DescribedRow(integration.name, detail: Text(verbatim: added(integration))) {
            AppIcon(integration: integration, side: 32)
        } trailing: {
            HStack(spacing: Spacing.tight) {
                if integration.application?.botID != nil { Chip(text: "Bot") }
                if integration.scopes.contains("applications.commands") { Chip(text: "Commands") }
                Button { page = .app(integration.id) } label: {
                    HStack(spacing: 2) {
                        Text("Manage")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func added(_ integration: GuildIntegration) -> String {
        let date = integration.addedAt.formatted(date: .abbreviated, time: .omitted)
        guard let installer = integration.installerID.flatMap({ model.users[$0] }) else {
            return "Added on \(date)"
        }
        return "Added on \(date) by \(installer.handle)"
    }

    // MARK: Sub-pages

    /// A page inside Integrations: the way back, its name, and its content.
    private func subpage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Button { page = .overview } label: {
                Label("Integrations", systemImage: "chevron.left")
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
}

/// The two creator platforms the page offers — Discord's names, lines and
/// explanations for each.
enum StreamingPlatform: String, Hashable {
    case twitch
    case youtube

    var kind: GuildIntegration.Kind { self == .twitch ? .twitch : .youtube }
    var title: String { self == .twitch ? "Twitch" : "YouTube" }
    var connectTitle: String { self == .twitch ? "Connect Twitch" : "Connect YouTube" }

    var line: String {
        self == .twitch
            ? "Sync your subscribers to roles and unlock your Twitch emotes"
            : "Sync your channel members to roles and create an exclusive experience"
    }

    var explanation: String {
        self == .twitch
            ? "Link your Twitch account to automatically sync your Twitch subs to roles in this server. You can also let your subs use your Twitch emotes globally in Discord."
            : "Link your YouTube account to automatically sync your YouTube channel members to roles in this server. Create an exclusive experience just for your channel members. YouTube integrations are only available for partnered YouTube accounts."
    }

    var syncedTitle: String { self == .twitch ? "Synced Subs" : "Synced Members" }

    /// Discord's count under it — subscribers on Twitch, members on YouTube.
    func subscribers(_ count: Int) -> String {
        switch self {
        case .twitch: count == 1 ? "1 subscriber" : "\(count) subscribers"
        case .youtube: count == 1 ? "1 member" : "\(count) members"
        }
    }

    var tint: Color { self == .twitch ? Color(hex: 0x9146FF) : Color(hex: 0xFF0000) }
    var symbolName: String { self == .twitch ? "tv" : "play.rectangle.fill" }
}

private struct PlatformMark: View {
    var platform: StreamingPlatform

    var body: some View {
        Image(symbol: platform.symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(platform.tint, in: .circle)
            .accessibilityHidden(true)
    }
}

private struct AppIcon: View {
    var integration: GuildIntegration
    var side: CGFloat

    var body: some View {
        RemoteImage(url: integration.application?.iconURL, side: side) {
            SettingsSurface.controlTrough.overlay {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// Discord's small grey chip — "Bot", "Commands".
private struct Chip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(SettingsSurface.controlTrough, in: .capsule)
    }
}

// MARK: - Webhooks

/// "New Webhook" and the cards. Discord's New Webhook makes one at once, in
/// the first channel it can post to, named by Discord.
private struct WebhookPage: View {
    let store: ServerSettingsStore
    let model: AppModel

    var body: some View {
        LoadableContent(store.webhooks) { webhooks in
            WebhookSection(
                store: store,
                model: model,
                webhooks: webhooks.filter { $0.kind == .incoming },
                createTitle: "New Webhook"
            ) {
                guard let first = store.textChannels.first else { return }
                Task { await store.createWebhook(in: first.id) }
            }
        }
    }
}

// MARK: - Twitch and YouTube

/// A platform's page: what it does, the syncs already on, and the reader's own
/// accounts on that platform to turn one on — or the way to link one.
private struct PlatformIntegrationPage: View {
    let store: ServerSettingsStore
    let model: AppModel
    var platform: StreamingPlatform

    @State private var disabling: GuildIntegration?
    @State private var isRefusingDisable = false

    var body: some View {
        let syncs = store.integrations.value?.filter { $0.kind == platform.kind } ?? []
        let accounts = (model.connections ?? []).filter { connection in
            connection.type == platform.rawValue && !syncs.contains { $0.accountName == connection.name }
        }
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text(platform.explanation)
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !syncs.isEmpty {
                SettingsCard {
                    ForEach(Array(syncs.enumerated()), id: \.element.id) { index, sync in
                        if index > 0 { CardDivider() }
                        syncRow(sync)
                    }
                }
            }
            SettingsCard {
                if accounts.isEmpty {
                    DescribedRow(platform.title, detail: nil) {
                        PlatformMark(platform: platform)
                    } trailing: {
                        Button(platform.connectTitle) {
                            model.sessionController.beginLinkingConnection(type: platform.rawValue)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { CardDivider() }
                    DescribedRow(account.name, detail: nil) {
                        PlatformMark(platform: platform)
                    } trailing: {
                        Button(platform.connectTitle) {
                            Task { await store.enableIntegration(type: platform.rawValue, accountID: account.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        // A link made in the browser shows up when the reader comes back.
        .onAppear { model.sessionController.refreshConnectedApps() }
        // Discord's confirm names what will happen to everybody: its button is
        // the behavior itself — Remove Role or Kick.
        .destructiveConfirmation(
            isPresented: Binding(get: { disabling != nil }, set: { if !$0 { disabling = nil } }),
            title: "Disable Sync",
            message: platform == .twitch
                ? "Disabling sync will perform the selected expired sub behavior as if all subs have expired."
                : "Disabling sync will perform the selected expired membership behavior as if all members have expired.",
            confirmTitle: (disabling?.expiry?.behavior ?? .removeRole).title
        ) {
            guard let disabling else { return }
            Task { await store.deleteIntegration(disabling.id) }
        }
        // Discord refuses outright where the behavior is a kick nobody here
        // may perform (`tr`'s `N`).
        .alert("Disable Sync", isPresented: $isRefusingDisable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(platform == .twitch
                ? "Disabling sync will perform the kick expired sub behavior as if all subs have expired, but you do not have kick permissions in this server."
                : "Disabling sync will perform the kick expired membership behavior as if all members have expired, but you do not have kick permissions in this server.")
        }
    }

    private var canKick: Bool { store.permissions.contains(.kickMembers) || store.permissions.contains(.administrator) }

    /// One sync, as Discord's expanded integration draws it (`tr`): the
    /// account and when it last ran, the role and how many it holds, what
    /// happens when a subscription lapses, Twitch's emotes, and Disable.
    @ViewBuilder
    private func syncRow(_ sync: GuildIntegration) -> some View {
        let role = sync.roleID.flatMap { id in store.roles.value?.first { $0.id == id } }
        DescribedRow(
            sync.accountName ?? sync.name,
            detail: syncDetail(sync)
        ) {
            PlatformMark(platform: platform)
        } trailing: {
            Button("Sync") { Task { await store.syncIntegration(sync.id) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sync.isRevoked)
        }
        CardDivider()
        DescribedRow("Synced Role", detail: Text(role.map { "@\($0.name)" } ?? "None")) {
            EmptyView()
        }
        CardDivider()
        DescribedRow(platform.syncedTitle, detail: Text(platform.subscribers(sync.subscriberCount ?? 0))) {
            EmptyView()
        }
        if let expiry = sync.expiry {
            CardDivider()
            SettingsPickerRow(
                title: platform == .twitch ? "Expired Sub Behavior" : "Expired Membership Behavior",
                options: GuildIntegration.Expiry.Behavior.allCases.map { .init($0, $0.title) },
                selection: Binding(
                    get: { expiry.behavior },
                    set: { behavior in
                        var next = expiry
                        next.behavior = behavior
                        Task { await store.updateIntegration(sync.id, expiry: next) }
                    }
                )
            )
            CardDivider()
            SettingsPickerRow(
                title: "Grace Period",
                options: GuildIntegration.Expiry.gracePeriods.map { .init($0, $0 == 1 ? "1 day" : "\($0) days") },
                selection: Binding(
                    get: { expiry.gracePeriod },
                    set: { days in
                        var next = expiry
                        next.gracePeriod = days
                        Task { await store.updateIntegration(sync.id, expiry: next) }
                    }
                )
            )
            if expiry.behavior == .kick, !canKick {
                Text("You do not have permission to kick members from this server.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Palette.destructive)
                    .padding(.horizontal, SettingsMetrics.cardContentInset)
                    .padding(.bottom, Spacing.snug)
            }
            if platform == .twitch {
                CardDivider()
                SettingsToggle(
                    title: "Allow synced subscribers to use your Twitch Custom Emoticons in Discord.",
                    isOn: Binding(
                        get: { expiry.enablesEmoticons },
                        set: { isOn in
                            var next = expiry
                            next.enablesEmoticons = isOn
                            Task { await store.updateIntegration(sync.id, expiry: next) }
                        }
                    )
                )
            }
        }
        CardDivider()
        DescribedRow("Disable Integration") {
            Button("Disable Integration", role: .destructive) {
                if sync.expiry?.behavior == .kick, !canKick {
                    isRefusingDisable = true
                } else {
                    disabling = sync
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Palette.destructive)
        }
    }

    /// "Last synced:" — or, where the link was taken back, Discord's line
    /// saying who must reconnect.
    private func syncDetail(_ sync: GuildIntegration) -> Text? {
        if sync.isRevoked {
            // Discord names the person who linked it, not the other service's
            // account.
            let who = sync.installerID.flatMap { model.users[$0]?.preferredName }
                ?? sync.accountName ?? sync.name
            return Text("Sync connection revoked! \(who) must reconnect to \(platform.title) in their user settings.")
        }
        return sync.syncedAt.map { Text("Last synced: \($0.formatted(date: .abbreviated, time: .shortened))") }
    }
}

// MARK: - One app

/// An app's own page: what it is, whether it has a bot here, and Remove App.
private struct AppIntegrationPage: View {
    let store: ServerSettingsStore
    let model: AppModel
    var integration: GuildIntegration
    var removed: () -> Void

    @State private var isRemoving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            SettingsCard {
                DescribedRow(
                    integration.name,
                    detail: integration.application?.description.map { Text(verbatim: $0) }
                ) {
                    AppIcon(integration: integration, side: 40)
                } trailing: {
                    EmptyView()
                }
                CardDivider()
                if let botID = integration.application?.botID {
                    DescribedRow(
                        "Bot",
                        detail: model.users[botID].map { Text(verbatim: $0.handle) }
                    ) {
                        EmptyView()
                    } trailing: {
                        EmptyView()
                    }
                } else {
                    Text("This application does not have a bot in this server.")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .padding(SettingsMetrics.cardContentInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Remove App", role: .destructive) { isRemoving = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Palette.destructive)
        }
        .destructiveConfirmation(
            isPresented: $isRemoving,
            title: "Remove App",
            message: "Removing this integration will remove any apps (including bots and webhooks) on this page from your server. This action cannot be undone.",
            confirmTitle: "Remove App"
        ) {
            Task {
                await store.deleteIntegration(integration.id)
                removed()
            }
        }
    }
}
