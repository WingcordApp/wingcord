import AppKit
import SwiftUI
import WingcordCore

// MARK: - Webhooks and followed channels
//
// Discord's integrations cards (`ec1f4aae`), shared by a channel's
// Integrations page and the server's Webhooks page: a webhook is a card that
// opens into its Name and Channel, Copy Webhook URL and Delete Webhook; a
// followed channel names what it follows and offers Unfollow. Every word is
// Discord's.
//
// **The URL is a credential**, so it is never drawn: Copy Webhook URL puts it
// on the pasteboard and says "Copied!" for a second, as Discord's tooltip does.

/// A channel's Integrations: its webhooks, and the announcement channels it
/// follows.
struct ChannelIntegrationsTab: View {
    let store: ServerSettingsStore
    let model: AppModel
    let channel: Channel

    var body: some View {
        LoadableContent(store.channelWebhookTable[channel.id] ?? .idle) { webhooks in
            VStack(alignment: .leading, spacing: 0) {
                WebhookSection(
                    store: store,
                    model: model,
                    webhooks: webhooks.filter { $0.kind == .incoming },
                    create: { Task { await store.createWebhook(in: channel.id) } }
                )
                FollowedChannelsSection(store: store, webhooks: webhooks.filter { $0.kind == .channelFollower })
            }
        }
        .task { await store.loadChannelWebhooks(channel.id) }
    }
}

/// "Webhooks", Create Webhook, and the cards — or "You have no webhooks!".
struct WebhookSection: View {
    let store: ServerSettingsStore
    let model: AppModel
    var webhooks: [GuildWebhook]
    /// "Create Webhook" on a channel, "New Webhook" on the server's page.
    var createTitle = "Create Webhook"
    var create: () -> Void

    @State private var expanded: UInt64?

    var body: some View {
        SettingsGroup("Webhooks") {
            SettingsCard {
                SettingsActionRow(createTitle, actionTitle: createTitle, action: create)
                if webhooks.isEmpty {
                    CardDivider()
                    Text("You have no webhooks!")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .padding(SettingsMetrics.cardContentInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(webhooks) { webhook in
                    CardDivider()
                    WebhookCard(
                        store: store,
                        model: model,
                        webhook: webhook,
                        isExpanded: Binding(
                            get: { expanded == webhook.id },
                            set: { expanded = $0 ? webhook.id : nil }
                        )
                    )
                }
            }
        }
    }
}

/// One webhook: its face, its name and when and by whom it was made; opened,
/// its Name and Channel, Copy Webhook URL and Delete Webhook.
private struct WebhookCard: View {
    let store: ServerSettingsStore
    let model: AppModel
    let webhook: GuildWebhook
    @Binding var isExpanded: Bool

    @State private var name = ""
    @State private var isCopied = false
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: SettingsMetrics.navigationIconGap) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: webhook.name)
                            .font(SettingsType.rowTitle)
                            .foregroundStyle(Ink.primary)
                        Text(verbatim: created)
                            .font(SettingsType.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: Spacing.base)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.leading, SettingsMetrics.navigationIconLeading)
                .padding(.trailing, SettingsMetrics.controlTrailing)
                .frame(minHeight: SettingsMetrics.navigationRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                editor
                    .padding(.horizontal, SettingsMetrics.cardContentInset)
                    .padding(.bottom, Spacing.snug)
            }
        }
        .onAppear { name = webhook.name }
        .onChange(of: webhook.name) { _, updated in name = updated }
        .destructiveConfirmation(
            isPresented: $isDeleting,
            title: "Delete \(webhook.name)",
            message: "Are you sure you want to delete the \(webhook.name) webhook? This action cannot be undone.",
            confirmTitle: "Delete"
        ) {
            Task { await store.deleteWebhook(webhook.id) }
        }
    }

    /// "Created on Mar 3, 2024 by name" — Discord's `7EcUbr`.
    private var created: String {
        let date = webhook.createdAt.formatted(date: .abbreviated, time: .omitted)
        guard let creator = webhook.creatorID.flatMap({ model.users[$0] }) else {
            return "Created on \(date)"
        }
        return "Created on \(date) by \(creator.handle)"
    }

    private var avatar: some View {
        RemoteImage(
            url: webhook.avatarHash.flatMap { CDN.avatar(userID: UserID(rawValue: webhook.id), hash: $0, side: 32) },
            side: 32
        ) {
            SettingsSurface.controlTrough.overlay {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(.circle)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(alignment: .top, spacing: Spacing.margin) {
                SheetField(title: "Name") {
                    TextField("", text: $name)
                        .modalField()
                        .onSubmit(rename)
                        .onChange(of: name) { _, typed in
                            if typed.count > 80 { name = String(typed.prefix(80)) }
                        }
                }
                SheetField(title: "Channel") {
                    FlyoutPicker(
                        selection: Binding(
                            get: { webhook.channelID },
                            set: { channelID in
                                Task { await store.saveWebhook(webhook.id, name: webhook.name, channelID: channelID) }
                            }
                        ),
                        options: store.textChannels.map { Optional($0.id) },
                        title: { id in id.flatMap { store.channelName($0) }.map { "#\($0)" } ?? "Select a Channel" },
                        accessibilityTitle: "Channel"
                    )
                }
            }
            HStack(spacing: Spacing.snug) {
                if webhook.url != nil {
                    Button(isCopied ? "Copied!" : "Copy Webhook URL") {
                        guard let url = webhook.url else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        isCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            isCopied = false
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                Button("Delete Webhook", role: .destructive) { isDeleting = true }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Palette.destructive)
                Spacer()
                if name != webhook.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Save Changes", action: rename)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .tint(Palette.accent)
                        .controlSize(.small)
                }
            }
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != webhook.name else { return }
        Task { await store.saveWebhook(webhook.id, name: trimmed, channelID: webhook.channelID) }
    }
}

/// "Channels Followed": what this channel receives, and Unfollow.
struct FollowedChannelsSection: View {
    let store: ServerSettingsStore
    var webhooks: [GuildWebhook]

    @State private var unfollowing: GuildWebhook?

    var body: some View {
        SettingsGroup("Channels Followed") {
            SettingsCard {
                if webhooks.isEmpty {
                    Text("You're not following any channels")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .padding(SettingsMetrics.cardContentInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(webhooks.enumerated()), id: \.element.id) { index, webhook in
                    if index > 0 { CardDivider() }
                    ObjectRow(
                        title: webhook.followedSource ?? webhook.name,
                        subtitle: store.channelName(webhook.channelID).map { "#\($0)" }
                    ) {
                        Image(systemName: "megaphone")
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: 28, height: 28)
                            .background(SettingsSurface.controlTrough, in: .circle)
                    } trailing: {
                        Button("Unfollow", role: .destructive) { unfollowing = webhook }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(Palette.destructive)
                    }
                }
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(get: { unfollowing != nil }, set: { if !$0 { unfollowing = nil } }),
            title: "Unfollow",
            message: "Are you sure you want to unfollow this channel? You can refollow it in the future by visiting the server it's from.",
            confirmTitle: "Unfollow"
        ) {
            guard let unfollowing else { return }
            Task { await store.deleteWebhook(unfollowing.id) }
        }
    }
}
