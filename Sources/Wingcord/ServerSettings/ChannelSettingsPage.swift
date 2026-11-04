import AppKit
import SwiftUI
import WingcordCore

// MARK: - A channel's settings
//
// Discord's Channel Settings (`13eee04b`): a sidebar of its own — the channel
// at the top with its category, then Overview, Permissions, Invites and
// Integrations, and Delete Channel under a divider — opened from the
// channel's own menu (`ServerSettingsWindow.open(_:channel:)`).
//
// **Each row is offered by the permission it needs**, as Discord's list is
// built: Permissions with Manage Permissions, Invites with Manage Channel on a
// channel that is not a category, Integrations with Manage Webhooks where the
// kind can hold webhooks, Delete with Manage Channel. The Overview edits with
// Manage Channel.

/// One page of a channel's settings — Discord's labels.
enum ChannelSettingsTab: String, Hashable, CaseIterable {
    case overview
    case permissions
    case invites
    case integrations

    var title: String {
        switch self {
        case .overview: "Overview"
        case .permissions: "Permissions"
        case .invites: "Invites"
        case .integrations: "Integrations"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "slider.horizontal.3"
        case .permissions: "shield.fill"
        case .invites: "link"
        case .integrations: "puzzlepiece.extension.fill"
        }
    }

    /// The rows this reader gets for this channel, in Discord's order.
    static func available(for channel: Channel, permissions: Permissions) -> [ChannelSettingsTab] {
        var tabs: [ChannelSettingsTab] = []
        if permissions.contains(.manageChannels) { tabs.append(.overview) }
        if permissions.contains(.manageRoles) { tabs.append(.permissions) }
        guard channel.kind != .category else { return tabs }
        if permissions.contains(.manageChannels) { tabs.append(.invites) }
        if channel.kind != .stage, permissions.contains(.manageWebhooks) { tabs.append(.integrations) }
        return tabs
    }
}

/// The channel's own sidebar.
struct ChannelSettingsSidebar: View {
    let store: ServerSettingsStore
    let model: AppModel
    let channel: Channel
    var guildName: String
    @Binding var selection: ChannelSettingsTab
    /// Back to the server's own settings.
    var close: () -> Void

    @State private var isDeleting = false
    @State private var refusal: ChannelDeleteGate.Refusal?

    var body: some View {
        let permissions = model.permissionGate.permissions(in: channel.id)
        let tabs = ChannelSettingsTab.available(for: channel, permissions: permissions)
        List(selection: selectionBinding) {
            header
            Section {
                ForEach(tabs, id: \.self) { tab in
                    Label {
                        Text(tab.title)
                    } icon: {
                        SettingsIconTile(
                            symbolName: tab.symbolName,
                            tint: Palette.accent,
                            side: SettingsMetrics.sidebarIconSide,
                            radius: SettingsMetrics.sidebarIconRadius
                        )
                    }
                    .tag(tab)
                }
            }
            if permissions.contains(.manageChannels) {
                Section {
                    Button {
                        // Discord refuses first and never asks the server.
                        if let reason = store.deleteRefusal(for: channel.id) {
                            refusal = reason
                        } else {
                            isDeleting = true
                        }
                    } label: {
                        Label {
                            Text(deleteTitle).foregroundStyle(Palette.destructive)
                        } icon: {
                            SettingsIconTile(
                                symbolName: "trash.fill",
                                tint: Palette.destructive,
                                side: SettingsMetrics.sidebarIconSide,
                                radius: SettingsMetrics.sidebarIconRadius
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Channel settings sections")
        .onAppear {
            if !tabs.contains(selection), let first = tabs.first { selection = first }
        }
        .modal(
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } }),
            style: .alert
        ) {
            ModalAlert(
                hero: .symbol("exclamationmark.lock.fill"),
                title: "Cannot Delete Channel",
                message: Text(refusal?.message ?? ""),
                actions: [.okay()]
            )
        }
        .destructiveConfirmation(
            isPresented: $isDeleting,
            title: deleteTitle,
            message: "Are you sure you want to delete \(model.displayName(of: channel))? This cannot be undone.",
            confirmTitle: deleteTitle
        ) {
            Task {
                await store.deleteChannel(channel.id)
                close()
            }
        }
    }

    private var deleteTitle: String {
        channel.kind == .category ? "Delete Category" : "Delete Channel"
    }

    private var selectionBinding: Binding<ChannelSettingsTab?> {
        Binding(
            get: { selection },
            set: { tab in
                if let tab { selection = tab }
            }
        )
    }

    /// The way back to the server's settings, then the channel — its mark,
    /// its name, and the category it sits in, as Discord's header has them.
    /// Not a row the selection can land on.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Button(action: close) {
                Label(guildName, systemImage: "chevron.left")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Back to \(guildName) settings"))
            HStack(spacing: Spacing.tight) {
                if channel.kind != .category {
                    Image(symbol: channel.kind.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(verbatim: channel.name)
                    .font(.headline)
                    .lineLimit(1)
                if let category = channel.parentID.flatMap({ model.channelIndex[$0] }) {
                    Text(verbatim: category.name.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.tight)
    }
}

/// One page of a channel's settings, under the detail pane's chrome.
struct ChannelSettingsContent: View {
    let store: ServerSettingsStore
    let model: AppModel
    let channel: Channel
    var tab: ChannelSettingsTab

    var body: some View {
        switch tab {
        case .overview:
            ChannelOverviewTab(store: store, channel: channel)
                .id(channel.id)
        case .permissions:
            ChannelPermissionsTab(store: store, model: model, channel: channel)
        case .invites:
            ChannelInvitesTab(store: store, model: model, channelID: channel.id)
        case .integrations:
            ChannelIntegrationsTab(store: store, model: model, channel: channel)
        }
    }
}

// MARK: - Overview

/// The Overview, edited on a draft with Discord's unsaved-changes bar.
private struct ChannelOverviewTab: View {
    let store: ServerSettingsStore
    let channel: Channel

    @State private var draft: ChannelOverview
    @State private var original: ChannelOverview

    init(store: ServerSettingsStore, channel: Channel) {
        self.store = store
        self.channel = channel
        _draft = State(initialValue: ChannelOverview(channel))
        _original = State(initialValue: ChannelOverview(channel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            SettingsGroup {
                SettingsCard {
                    VStack(alignment: .leading, spacing: Spacing.margin) {
                        ChannelOverviewForm(
                            overview: $draft,
                            maximumBitrate: store.maximumBitrate,
                            regions: store.voiceRegions.value ?? [],
                            offersSummaries: store.offersSummaries
                        )
                    }
                    .padding(SettingsMetrics.cardContentInset)
                }
            }
            if draft != original {
                UnsavedChangesBar(
                    canSave: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    reset: { draft = original },
                    save: {
                        let saved = draft
                        Task {
                            await store.saveChannel(saved)
                            original = saved
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            guard ChannelOverview(channel).isVoice else { return }
            await store.loadVoiceRegions()
        }
        // An edit landing from elsewhere reseeds a page with nothing unsaved
        // on it, and leaves a draft somebody is in the middle of alone.
        .onChange(of: channel) { _, updated in
            guard draft == original else { return }
            draft = ChannelOverview(updated)
            original = draft
        }
    }
}

/// Discord's bar for an edited page: "Careful — you have unsaved changes!",
/// Reset, and Save Changes.
struct UnsavedChangesBar: View {
    var canSave = true
    var reset: () -> Void
    var save: () -> Void

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Text("Careful — you have unsaved changes!")
                .font(SettingsType.rowTitle)
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Spacing.base)
            Button("Reset", action: reset)
                .buttonStyle(.link)
            Button("Save Changes", action: save)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Palette.affirmative)
                .disabled(!canSave)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.snug)
        .background(SettingsSurface.controlTrough, in: .settingsRect(SettingsMetrics.cardRadius))
    }
}

// MARK: - Invites

/// "Here's a list of all active invite links. You can revoke any one."
private struct ChannelInvitesTab: View {
    let store: ServerSettingsStore
    let model: AppModel
    let channelID: ChannelID

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Here's a list of all active invite links. You can revoke any one.")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
            LoadableContent(
                store.channelInviteTable[channelID] ?? .idle,
                isEmpty: \.isEmpty,
                empty: { EmptyRow(message: "No invites yet!", symbolName: "link") }
            ) { invites in
                SettingsGroup {
                    SettingsCard {
                        ForEach(Array(invites.enumerated()), id: \.element.id) { index, invite in
                            if index > 0 { CardDivider() }
                            row(invite)
                        }
                    }
                }
            }
        }
        .task { await store.loadChannelInvites(channelID) }
    }

    /// Discord's four columns — Inviter, Invite Code, Uses, Expires — and Remove.
    private func row(_ invite: GuildInvite) -> some View {
        let inviter = invite.inviterID.flatMap { model.users[$0] }
        return ObjectRow(
            title: StreamerMode.shared.inviteCode(invite.id),
            subtitle: inviter.map { $0.preferredName },
            badge: invite.isUnlimitedUses ? "\(invite.uses)" : "\(invite.uses)/\(invite.maxUses)"
        ) {
            AvatarView(
                url: inviter.flatMap { model.avatarURL(for: $0, side: 28) },
                monogram: String(inviter?.preferredName.prefix(1) ?? "#"),
                side: 28
            )
        } trailing: {
            HStack(spacing: Spacing.base) {
                Group {
                    if let expiry = invite.expiresAt {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: InviteCountdown.text(until: expiry, now: context.date))
                                .monospacedDigit()
                        }
                    } else {
                        Text("Never")
                    }
                }
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                RowIconButton(symbolName: "trash", label: "Remove", role: .destructive) {
                    Task { await store.revokeChannelInvite(invite.id, in: channelID) }
                }
            }
        }
    }
}

/// An invite's Expires column: Discord's countdown without days (`576470`
/// with `showDays: false`) — hours run past twenty-four.
enum InviteCountdown {
    static func text(until end: Date, now: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now)))
        let parts = [remaining / 3600, remaining % 3600 / 60, remaining % 60]
        return parts.map { $0 < 10 ? "0\($0)" : "\($0)" }.joined(separator: ":")
    }
}
