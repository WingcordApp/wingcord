import AppKit
import SwiftUI
import WingcordCore

// MARK: - Roles

/// The list, and the editor behind each row.
///
/// **Ordering is the one delta in this whole surface.** Every other write on
/// these pages sends its page's fields whole; `PATCH /guilds/{id}/roles` sends
/// only the roles that moved, and the response is every role in the server —
/// because a move renumbers whatever it displaced. So a drag stores the
/// response rather than the optimistic order, or the next drag is computed from
/// positions nobody holds.
struct RolesPane: View {
    let store: ServerSettingsStore

    @State private var editing: RoleID?
    @State private var deleting: Role?
    @State private var query = ""

    var body: some View {
        LoadableContent(store.roles) { roles in
            let everyone = roles.first { $0.isEveryone(in: store.guildID) }
            let ordered = roles
                .filter { !$0.isEveryone(in: store.guildID) }
                .sorted(by: Role.seniorityOrder)
            let shown = filtered(ordered)

            VStack(alignment: .leading, spacing: 0) {
                if let everyone {
                    SettingsGroup("Default Permissions") {
                        SettingsCard {
                            ObjectRow(
                                title: "@everyone"
                            ) {
                                RoleSwatch(role: everyone)
                            } trailing: {
                                RowIconButton(
                                    symbolName: "pencil",
                                    label: "Edit"
                                ) {
                                    editing = everyone.id
                                }
                            }
                        }
                    }
                }

                SettingsGroup("Roles — \(ordered.count)") {
                    SettingsCard {
                        SettingsActionRow(
                            "Create Role",
                            actionTitle: "Create Role"
                        ) {
                            Task { await store.createRole() }
                        }
                        if ordered.count > 6 {
                            CardDivider()
                            SearchRow(query: $query, placeholder: "Search Roles")
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { _, role in
                            CardDivider()
                            row(role, all: ordered)
                        }
                    }
                }
            }
            .sheet(item: Binding(
                get: { editing.flatMap { id in roles.first { $0.id == id } } },
                set: { editing = $0?.id }
            )) { role in
                RoleSheet(
                    role: role,
                    guildID: store.guildID,
                    allowsStyles: store.settings.value?.features.contains("ENHANCED_ROLE_COLORS") ?? false
                ) { updated in
                    Task { await store.saveRole(updated) }
                }
            }
        }
    }

    private func filtered(_ roles: [Role]) -> [Role] {
        guard !query.isEmpty else { return roles }
        let needle = query.lowercased()
        return roles.filter { $0.name.lowercased().contains(needle) }
    }

    private func row(_ role: Role, all: [Role]) -> some View {
        ObjectRow(
            title: role.name,
            subtitle: subtitle(role),
            badge: memberCount(role)
        ) {
            RoleSwatch(role: role)
        } trailing: {
            HStack(spacing: 2) {
                // Arrows rather than a drag: a drag inside a scrolling settings
                // pane fights the scroll, and two buttons say exactly what they
                // do. Disabled at the ends, because a control that is a no-op is
                // §5.5's inert control in miniature.
                RowIconButton(symbolName: "chevron.up", label: "Move \(role.name) up") {
                    move(role, in: all, by: -1)
                }
                .disabled(all.first?.id == role.id)
                RowIconButton(symbolName: "chevron.down", label: "Move \(role.name) down") {
                    move(role, in: all, by: 1)
                }
                .disabled(all.last?.id == role.id)

                if role.isEditable {
                    RowIconButton(symbolName: "pencil", label: "Edit \(role.name)") {
                        editing = role.id
                    }
                    RowIconButton(
                        symbolName: "trash",
                        label: "Delete \(role.name)",
                        role: .destructive
                    ) {
                        deleting = role
                    }
                }
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { deleting?.id == role.id },
                set: { if !$0 { deleting = nil } }
            ),
            title: "Delete Role",
            message: "Are you sure you want to delete the \(role.name) role? This action cannot be undone.",
            confirmTitle: "Delete"
        ) {
            Task { await store.deleteRole(role.id) }
        }
    }

    private func subtitle(_ role: Role) -> String? {
        if role.isManaged { return "Managed by an integration" }
        if let description = role.description { return description }
        if role.permissions.contains(.administrator) { return "Administrator" }
        return nil
    }

    private func memberCount(_ role: Role) -> String? {
        guard let count = store.roleMemberCounts[role.id] else { return nil }
        return count == 1 ? "1 member" : "\(count) members"
    }

    /// Swaps a role with its neighbour and sends **both** positions.
    ///
    /// Both, because Discord's ordering is by `position` and swapping means two
    /// roles change — a request naming only the one that moved leaves two roles
    /// claiming the same slot, which the server resolves by id and not by intent.
    private func move(_ role: Role, in ordered: [Role], by offset: Int) {
        guard let index = ordered.firstIndex(where: { $0.id == role.id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        let other = ordered[target]
        Task {
            await store.reorderRoles([
                (id: role.id, position: other.position),
                (id: other.id, position: role.position),
            ])
        }
    }
}

/// A role's colour, or the absence of one.
///
/// **Zero is "no colour", not black** — `Role.displayColorValue` is where that
/// is decided, and this draws a hollow ring for the nil case rather than a black
/// dot on a near-black card.
struct RoleSwatch: View {
    var role: Role

    var body: some View {
        Group {
            if let colors = role.colors, colors.isGradient {
                Circle().fill(
                    LinearGradient(
                        colors: [
                            Color(hex: colors.primary),
                            Color(hex: colors.secondary ?? colors.primary),
                            Color(hex: colors.tertiary ?? colors.secondary ?? colors.primary),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            } else if let value = role.displayColorValue {
                Circle().fill(Color(hex: value))
            } else {
                Circle().strokeBorder(Ink.tertiary, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

/// A search field that lives inside a card.
struct SearchRow: View {
    @Binding var query: String
    var placeholder: String

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(SettingsType.rowLabel)
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .frame(height: SettingsMetrics.controlRowHeight)
    }
}

// MARK: - Invites

struct InvitesPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    SettingsActionRow(
                        "Create Invite Link",
                        help: "Create an invite link anyone can use to join, or invite friends directly.",
                        actionTitle: "Create Invite Link"
                    ) {
                        isCreating = true
                    }
                }
            }

            LoadableContent(
                store.invites,
                isEmpty: \.isEmpty,
                empty: { EmptyRow(message: "No active invite links", symbolName: "link") }
            ) { invites in
                SettingsGroup("Active invite links") {
                    SettingsCard {
                        ForEach(Array(invites.enumerated()), id: \.element.id) { index, invite in
                            if index > 0 { CardDivider() }
                            row(invite)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            InviteSheet(channels: store.textChannels) { channelID, options in
                Task { await store.createInvite(in: channelID, options: options) }
            }
        }
    }

    private func row(_ invite: GuildInvite) -> some View {
        ObjectRow(
            title: invite.id,
            subtitle: subtitle(invite),
            badge: uses(invite)
        ) {
            Image(systemName: "link")
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28)
                .background(SettingsSurface.controlTrough, in: .circle)
        } trailing: {
            HStack(spacing: 2) {
                RowIconButton(symbolName: "doc.on.doc", label: "Copy Link") {
                    guard let url = invite.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                // Discord's X revokes at once, as it does here.
                RowIconButton(
                    symbolName: "trash",
                    label: "Revoke",
                    role: .destructive
                ) {
                    Task { await store.deleteInvite(invite.id) }
                }
            }
        }
    }

    private func subtitle(_ invite: GuildInvite) -> String {
        var parts: [String] = []
        if let name = invite.channelName { parts.append("#\(name)") }
        if let inviter = invite.inviterID, let user = model.users[inviter] {
            parts.append("by \(user.preferredName)")
        }
        if invite.hasExpired() {
            parts.append("expired")
        } else if let expiry = invite.expiresAt {
            parts.append("expires \(expiry.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never expires")
        }
        return parts.joined(separator: " · ")
    }

    private func uses(_ invite: GuildInvite) -> String {
        invite.isUnlimitedUses ? "\(invite.uses) uses" : "\(invite.uses)/\(invite.maxUses)"
    }
}

/// The create-invite form.
struct InviteSheet: View {
    var channels: [ServerSettingsStore.ChannelSummary]
    var commit: (ChannelID, InviteOptions) -> Void

    @State private var channelID: ChannelID?
    @State private var options = InviteOptions()

    var body: some View {
        SheetFrame(
            title: "Server invite link settings",
            confirmTitle: "Generate a New Link",
            canConfirm: channelID != nil
        ) {
            guard let channelID else { return }
            commit(channelID, options)
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

            SheetField(title: "Expire After") {
                Picker("", selection: $options.maxAge) {
                    ForEach(InviteOptions.ageChoices, id: \.self) { seconds in
                        Text(InviteOptions.ageTitle(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
            }

            SheetField(title: "Max Number of Uses") {
                Picker("", selection: $options.maxUses) {
                    ForEach(InviteOptions.useChoices, id: \.self) { uses in
                        Text(InviteOptions.usesTitle(uses)).tag(uses)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: Spacing.tight) {
                Toggle("Grant temporary membership", isOn: $options.isTemporary)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("Temporary members are automatically kicked when they disconnect unless a role has been assigned")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // The first channel, so the sheet opens usable. Discord's own picker
            // defaults to wherever you were.
            if channelID == nil { channelID = channels.first?.id }
        }
    }
}

// MARK: - Bans

struct BansPane: View {
    let store: ServerSettingsStore

    @State private var query = ""
    @State private var lifting: GuildBan?

    var body: some View {
        LoadableContent(
            store.bans,
            isEmpty: \.isEmpty,
            empty: {
                EmptyRow(
                    message: "No Bans — You haven\u{2019}t banned anybody... but if and when you must, do not hesitate!",
                    symbolName: "hand.raised"
                )
            }
        ) { bans in
            let shown = filtered(bans)
            SettingsGroup("Server Ban List") {
                SettingsCard {
                    if bans.count > 6 {
                        SearchRow(query: $query, placeholder: "Search Bans by User Id or Username")
                        CardDivider()
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, ban in
                        if index > 0 { CardDivider() }
                        row(ban)
                    }
                }
            }
        }
    }

    private func filtered(_ bans: [GuildBan]) -> [GuildBan] {
        guard !query.isEmpty else { return bans }
        let needle = query.lowercased()
        return bans.filter {
            $0.username.lowercased().contains(needle)
                || ($0.displayName?.lowercased().contains(needle) ?? false)
                || String($0.id.rawValue) == query
        }
    }

    private func row(_ ban: GuildBan) -> some View {
        ObjectRow(
            title: ban.displayName ?? ban.username,
            subtitle: ban.reason,
            badge: ban.displayName == nil ? nil : ban.username
        ) {
            RemoteImage(
                url: ban.avatarHash.flatMap {
                    CDN.avatar(userID: ban.id, hash: $0, side: 28)
                },
                side: 28
            ) {
                Circle().fill(SettingsSurface.controlTrough)
            }
            .frame(width: 28, height: 28)
            .clipShape(.circle)
        } trailing: {
            RowIconButton(symbolName: "arrow.uturn.backward", label: "Revoke Ban") {
                lifting = ban
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { lifting?.id == ban.id },
                set: { if !$0 { lifting = nil } }
            ),
            title: ban.displayName ?? ban.username,
            message: ban.reason.map { "Ban Reason: \($0)" } ?? "Ban Reason",
            confirmTitle: "Revoke Ban"
        ) {
            Task { await store.unban(ban.id) }
        }
    }
}
