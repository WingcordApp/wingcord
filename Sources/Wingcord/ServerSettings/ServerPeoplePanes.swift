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
                    SettingsGroup("Default permissions") {
                        SettingsCard {
                            ObjectRow(
                                title: "@everyone",
                                subtitle: "Applies to every member of this server"
                            ) {
                                RoleSwatch(role: everyone)
                            } trailing: {
                                RowIconButton(
                                    symbolName: "pencil",
                                    label: "Edit default permissions"
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
                            "Create a role",
                            help: "Roles group members and grant permissions.",
                            actionTitle: "Create"
                        ) {
                            Task { await store.createRole() }
                        }
                        if ordered.count > 6 {
                            CardDivider()
                            SearchRow(query: $query, placeholder: "Search roles")
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { _, role in
                            CardDivider()
                            row(role, all: ordered)
                        }
                    }
                    SettingsFootnote(
                        "Members take the colour of the highest role on this list "
                            + "that has one. Use the arrows to reorder."
                    )
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
            title: "Delete \(role.name)?",
            message: "Everyone who has it loses its permissions, and its colour, immediately.",
            confirmTitle: "Delete role"
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
    @State private var revoking: GuildInvite?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    SettingsActionRow(
                        "Create an invite link",
                        help: "Choose a channel, how long it lasts and how many people may use it.",
                        actionTitle: "Create"
                    ) {
                        isCreating = true
                    }
                }
            }

            LoadableContent(
                store.invites,
                isEmpty: \.isEmpty,
                empty: { EmptyRow(message: "No active invite links.", symbolName: "link") }
            ) { invites in
                SettingsGroup("Active links — \(invites.count)") {
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
                RowIconButton(symbolName: "doc.on.doc", label: "Copy link") {
                    guard let url = invite.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                RowIconButton(
                    symbolName: "trash",
                    label: "Revoke this link",
                    role: .destructive
                ) {
                    revoking = invite
                }
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { revoking?.id == invite.id },
                set: { if !$0 { revoking = nil } }
            ),
            title: "Revoke \(invite.id)?",
            message: "Anyone holding this link will no longer be able to use it.",
            confirmTitle: "Revoke"
        ) {
            Task { await store.deleteInvite(invite.id) }
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
            title: "Create an invite link",
            confirmTitle: "Create",
            canConfirm: channelID != nil
        ) {
            guard let channelID else { return }
            commit(channelID, options)
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

            SheetField(title: "Expires after") {
                Picker("", selection: $options.maxAge) {
                    ForEach(InviteOptions.ageChoices, id: \.self) { seconds in
                        Text(InviteOptions.ageTitle(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
            }

            SheetField(title: "Maximum uses") {
                Picker("", selection: $options.maxUses) {
                    ForEach(InviteOptions.useChoices, id: \.self) { uses in
                        Text(InviteOptions.usesTitle(uses)).tag(uses)
                    }
                }
                .labelsHidden()
            }

            SheetField(
                title: "Membership",
                detail: "A temporary member is removed when they disconnect, "
                    + "unless somebody gives them a role first."
            ) {
                Toggle("Grant temporary membership", isOn: $options.isTemporary)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .task {
            // The first channel, so the sheet opens usable. Discord's own picker
            // defaults to wherever you were.
            if channelID == nil { channelID = channels.first?.id }
        }
    }
}

// MARK: - Access

struct AccessPane: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.settings) { settings in
            VStack(alignment: .leading, spacing: 0) {
                joinMode(settings)
                ageGate(settings)
                application(settings)
            }
        }
    }

    /// The three tiles.
    ///
    /// **Three routes behind one control**, which is why the mode is resolved in
    /// `GuildAccessMode` rather than at each tile: Invite Only is the absence of
    /// the other two, Apply to Join is `PATCH /member-verification`, and
    /// Discoverable is a guild feature Discord refuses until six requirements
    /// are met.
    private func joinMode(_ settings: GuildSettings) -> some View {
        let mode = GuildAccessMode(
            features: settings.features,
            hasJoinForm: store.joinForm.value?.isEnabled ?? false
        )
        return SettingsGroup("How people join") {
            HStack(spacing: Spacing.base) {
                ForEach(GuildAccessMode.allCases) { candidate in
                    AccessTile(
                        mode: candidate,
                        isSelected: candidate == mode,
                        isEnabled: isSelectable(candidate, settings: settings)
                    ) {
                        choose(candidate, settings: settings)
                    }
                }
            }
            if !(store.discoveryRequirements.value?.isSufficient ?? true) {
                DiscoveryRequirementsCard(store: store)
            }
        }
    }

    private func ageGate(_ settings: GuildSettings) -> some View {
        SettingsGroup("Age") {
            SettingsCard {
                SettingsToggle(
                    title: "Age-restricted server",
                    help: "Members confirm they are over the legal age before they can see anything here.",
                    isOn: Binding(
                        get: { settings.contentLevel.isAgeRestricted },
                        set: { isOn in
                            Task { await store.saveContentLevel(isOn ? .ageRestricted : .default) }
                        }
                    )
                )
            }
            // Discord's own classification is separate from the owner's switch
            // and cannot be set from here, so it is stated rather than offered.
            if settings.nsfwLevel != 0 {
                SettingsFootnote(
                    "Discord has separately classified this server's content. "
                        + "That classification is not something this switch changes.",
                    symbolName: "info.circle"
                )
            }
        }
    }

    @ViewBuilder
    private func application(_ settings: GuildSettings) -> some View {
        let mode = GuildAccessMode(
            features: settings.features,
            hasJoinForm: store.joinForm.value?.isEnabled ?? false
        )
        if mode == .applyToJoin || store.joinForm.value?.fields.isEmpty == false {
            LoadableContent(store.joinForm) { form in
                JoinFormEditor(form: form) { updated in
                    Task { await store.saveJoinForm(updated) }
                }
            }
        }
    }

    /// Whether a tile can be pressed.
    ///
    /// Discoverable is refused outright until the server meets its requirements,
    /// and the reference client's own answer is a toast saying so *after* the
    /// press. Disabling it and stating the reasons underneath is the same
    /// information, before the press rather than after.
    private func isSelectable(_ mode: GuildAccessMode, settings: GuildSettings) -> Bool {
        switch mode {
        case .inviteOnly, .applyToJoin: true
        case .discoverable: store.discoveryRequirements.value?.isSufficient ?? false
        }
    }

    private func choose(_ mode: GuildAccessMode, settings: GuildSettings) {
        switch mode {
        case .inviteOnly:
            // Turning the form off is the whole of it — discovery is a feature
            // this client does not add or remove, because applying to discovery
            // is a submission rather than a switch.
            guard var form = store.joinForm.value else { return }
            form.isEnabled = false
            Task { await store.saveJoinForm(form) }
        case .applyToJoin:
            var form = store.joinForm.value ?? JoinApplicationForm(guildID: store.guildID)
            if form.fields.isEmpty {
                form.fields = [
                    JoinApplicationForm.Field(label: "Why do you want to join our server?")
                ]
            }
            form.isEnabled = true
            Task { await store.saveJoinForm(form) }
        case .discoverable:
            // Deliberately unreachable while the tile is disabled, and left
            // without an implementation rather than given a wrong one: joining
            // discovery is an application with a category and keywords, not a
            // feature flag a client may set.
            break
        }
    }
}

private struct AccessTile: View {
    var mode: GuildAccessMode
    var isSelected: Bool
    var isEnabled: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Spacing.base) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                Text(mode.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                Text(mode.detail)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.margin)
            .padding(.horizontal, Spacing.snug)
            .background(
                isSelected ? SettingsSurface.controlSelected : SettingsSurface.card,
                in: .settingsRect(10)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Why discovery is refused.
private struct DiscoveryRequirementsCard: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.discoveryRequirements) { requirements in
            SettingsCard {
                ForEach(Array(requirements.requirements.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { CardDivider() }
                    HStack(alignment: .top, spacing: Spacing.snug) {
                        Image(systemName: symbol(item.outcome))
                            .font(.system(size: 13))
                            .foregroundStyle(tint(item.outcome))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(SettingsType.rowTitle)
                                .foregroundStyle(Ink.primary)
                            Text(item.detail)
                                .font(SettingsType.rowSubtitle)
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsMetrics.cardContentInset)
                    .padding(.vertical, Spacing.snug)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func symbol(_ outcome: DiscoveryRequirements.Requirement.Outcome) -> String {
        switch outcome {
        case .met: "checkmark.circle.fill"
        case .unmet: "xmark.circle.fill"
        case .pending: "exclamationmark.circle.fill"
        }
    }

    /// **Pending is not a failure.** Discord cannot measure activity below a
    /// couple of hundred members, which is the ordinary case — drawing it as a
    /// cross would tell most servers they had failed something nobody has
    /// measured.
    private func tint(_ outcome: DiscoveryRequirements.Requirement.Outcome) -> Color {
        switch outcome {
        case .met: Palette.affirmative
        case .unmet: Palette.destructive
        case .pending: .orange
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
            empty: { EmptyRow(message: "Nobody is banned from this server.", symbolName: "hand.raised") }
        ) { bans in
            let shown = filtered(bans)
            SettingsGroup("Banned — \(bans.count)") {
                SettingsCard {
                    if bans.count > 6 {
                        SearchRow(query: $query, placeholder: "Search bans")
                        CardDivider()
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, ban in
                        if index > 0 { CardDivider() }
                        row(ban)
                    }
                }
                SettingsFootnote(
                    "Discord does not record when a ban was issued, so this list "
                        + "cannot be sorted by date."
                )
            }
        }
    }

    private func filtered(_ bans: [GuildBan]) -> [GuildBan] {
        guard !query.isEmpty else { return bans }
        let needle = query.lowercased()
        return bans.filter {
            $0.username.lowercased().contains(needle)
                || ($0.displayName?.lowercased().contains(needle) ?? false)
        }
    }

    private func row(_ ban: GuildBan) -> some View {
        ObjectRow(
            title: ban.displayName ?? ban.username,
            subtitle: ban.reason ?? "No reason given",
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
            RowIconButton(symbolName: "arrow.uturn.backward", label: "Lift this ban") {
                lifting = ban
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { lifting?.id == ban.id },
                set: { if !$0 { lifting = nil } }
            ),
            title: "Lift the ban on \(ban.displayName ?? ban.username)?",
            message: "They will be able to rejoin with a new invite.",
            confirmTitle: "Lift ban"
        ) {
            Task { await store.unban(ban.id) }
        }
    }
}
