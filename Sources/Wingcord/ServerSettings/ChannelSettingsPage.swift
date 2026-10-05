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

    @Namespace private var pill
    @Environment(\.motion) private var motion
    @State private var isDeleting = false
    @State private var refusal: ChannelDeleteGate.Refusal?

    var body: some View {
        let permissions = model.permissionGate.permissions(in: channel.id)
        let tabs = ChannelSettingsTab.available(for: channel, permissions: permissions)
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SettingsMetrics.sidebarRowSpacing) {
                    ForEach(tabs, id: \.self) { tab in
                        ChannelSettingsSidebarRow(
                            title: tab.title,
                            symbolName: tab.symbolName,
                            isSelected: tab == selection,
                            pill: pill
                        ) { selection = tab }
                    }
                    if permissions.contains(.manageChannels) {
                        Divider()
                            .padding(.vertical, Spacing.base)
                            .padding(.horizontal, SettingsMetrics.sidebarRowLeading)
                        ChannelSettingsSidebarRow(
                            title: deleteTitle,
                            symbolName: "trash.fill",
                            isDestructive: true,
                            isSelected: false,
                            pill: pill
                        ) {
                            // Discord refuses first and never asks the server.
                            if let reason = store.deleteRefusal(for: channel.id) {
                                refusal = reason
                            } else {
                                isDeleting = true
                            }
                        }
                    }
                }
                .padding(.horizontal, SettingsMetrics.sidebarRowInset)
                .padding(.top, SettingsMetrics.sidebarListTopInset)
                .padding(.bottom, SettingsMetrics.sidebarRowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion.glassMorph, value: selection)
            }
            .scrollBounceBehavior(.basedOnSize)
            .softScrollEdgesVertical()
        }
        .frame(width: SettingsMetrics.sidebarWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Channel settings sections")
        .onAppear {
            if !tabs.contains(selection), let first = tabs.first { selection = first }
        }
        .alert(
            "Cannot Delete Channel",
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
        ) {
            Button("Okay", role: .cancel) {}
        } message: {
            Text(refusal?.message ?? "")
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

    /// The way back to the server's settings, then the channel — its mark,
    /// its name, and the category it sits in, as Discord's header has them.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Button(action: close) {
                Label(guildName, systemImage: "chevron.left")
                    .font(.system(.caption, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .accessibilityLabel(Text("Back to \(guildName) settings"))
            HStack(spacing: Spacing.tight) {
                if channel.kind != .category {
                    Image(symbol: channel.kind.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .accessibilityHidden(true)
                }
                Text(verbatim: channel.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let category = channel.parentID.flatMap({ model.channelIndex[$0] }) {
                    Text(verbatim: category.name.uppercased())
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.sidebarRowInset + 2)
        .padding(.top, SettingsMetrics.searchFieldTop)
    }
}

private struct ChannelSettingsSidebarRow: View {
    var title: String
    var symbolName: String
    var isDestructive = false
    var isSelected: Bool
    var pill: Namespace.ID
    var select: () -> Void

    @State private var isHovering = false
    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: select) {
            HStack(spacing: SettingsMetrics.sidebarIconGap) {
                SettingsIconTile(
                    symbolName: symbolName,
                    tint: isDestructive ? Palette.destructive : Palette.accent,
                    side: SettingsMetrics.sidebarIconSide,
                    radius: SettingsMetrics.sidebarIconRadius
                )
                Text(title)
                    .font(.system(.subheadline))
                    .foregroundStyle(isDestructive ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, SettingsMetrics.sidebarRowLeading)
            .padding(.trailing, Spacing.tight)
            .frame(height: SettingsMetrics.sidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: SettingsMetrics.sidebarRowRadius, style: .continuous)
                        .fill(SettingsSurface.rowSelected)
                        .matchedGeometryEffect(id: "selection", in: pill)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: SettingsMetrics.sidebarRowRadius, style: .continuous)
                        .fill(SettingsSurface.rowHover)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(motion.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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
                .tint(Palette.affirmative)
                .disabled(!canSave)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.snug)
        .background(SettingsSurface.controlTrough, in: .settingsRect(SettingsMetrics.paneRadius))
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
            title: invite.id,
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
