import SwiftUI
import WingcordCore

// MARK: - A channel's Permissions
//
// Discord's page (`13eee04b`), top to bottom: whether the channel follows its
// category, the Private Channel switch and who can get in, then Advanced
// permissions — every role and member with an overwrite, and the three-way
// switch for each permission the kind of channel lists
// (`ChannelPermissionCatalog`).
//
// **Advanced edits are a draft, saved together** behind Discord's
// unsaved-changes bar: a page of forty switches that wrote on every click
// would be forty requests for one decision. The switch, the access list and
// Sync Now write at once, as Discord's do.

struct ChannelPermissionsTab: View {
    let store: ServerSettingsStore
    let model: AppModel
    let channel: Channel

    @State private var isSyncing = false
    @State private var removing: Subject?

    /// A role or a member, as the access list and the editor name them.
    struct Subject: Hashable, Identifiable {
        var id: UInt64
        var kind: PermissionOverwrite.Subject
        var name: String
    }

    private var guildID: GuildID { channel.guildID ?? GuildID(rawValue: 0) }
    private var isCategory: Bool { channel.kind == .category }

    var body: some View {
        let isPrivate = ChannelAccess.isPrivate(channel, guildID: guildID)
        VStack(alignment: .leading, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(isCategory ? "Category Settings" : "Channel Permissions")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(isCategory
                    ? "Use permissions to customize who can do what in this category."
                    : "Use permissions to customize who can do what in this channel.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
            }
            syncNotice
            privacy(isPrivate: isPrivate)
            AdvancedPermissionsEditor(store: store, model: model, channel: channel)
        }
        .modal(isPresented: $isSyncing, style: .alert) {
            ModalAlert(
                hero: .symbol("arrow.triangle.2.circlepath"),
                title: "Sync permissions?",
                message: parent.map { category in
                    Text("Would you like to sync \(model.displayName(of: channel)) permissions with \(category.name)?")
                },
                actions: [
                    .cancel(),
                    .act("Sync Permissions", symbol: "arrow.triangle.2.circlepath") { sync() },
                ]
            )
        }
        .modal(
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            style: .alert
        ) {
            if let removing {
                ModalAlert(
                    hero: .symbol("lock.slash.fill"),
                    title: "Delete Permission Settings",
                    message: Text("Are you sure you want to delete \(removing.name) permissions? This action cannot be undone."),
                    actions: [
                        .cancel(),
                        // Discord's word; no Return — it cannot be undone.
                        .act("Okay", symbol: "trash", irreversible: true) {
                            Task { await store.removeOverwrite(removing.id, in: channel.id) }
                        },
                    ]
                )
            }
        }
    }

    // MARK: Sync

    private var parent: Channel? {
        channel.parentID.flatMap { model.channelIndex[$0] }
    }

    @ViewBuilder
    private var syncNotice: some View {
        if let category = parent,
           model.permissionGate.permissions(in: category.id).contains(.manageRoles)
        {
            let synced = ChannelAccess.isSynced(channel, with: category)
            HStack(spacing: Spacing.snug) {
                Image(symbol: synced ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.presenceIdle)
                Text(synced
                    ? "Permissions synced with category: **\(category.name)**"
                    : "Permissions not synced with category: **\(category.name)**")
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Spacing.base)
                if !synced {
                    Button("Sync Now") { isSyncing = true }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
            .padding(SettingsMetrics.cardContentInset)
            .background(Palette.presenceIdle.opacity(0.12), in: .settingsRect(SettingsMetrics.cardRadius))
        }
    }

    private func sync() {
        guard let category = parent else { return }
        Task { await store.syncWithCategory(channel.id, overwrites: category.overwrites) }
    }

    // MARK: Private Channel

    @ViewBuilder
    private func privacy(isPrivate: Bool) -> some View {
        let roles = model.roles[guildID] ?? [:]
        let everyone = roles[RoleID(rawValue: guildID.rawValue)]
        let everyoneIsAdmin = everyone?.permissions.contains(.administrator) ?? false
        let everyoneCanView = everyone?.permissions.contains(.viewChannel) ?? true
        SettingsGroup {
            SettingsCard {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(spacing: Spacing.snug) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Ink.secondary)
                        Text(isCategory ? "Private Category" : "Private Channel")
                            .font(SettingsType.rowTitle)
                            .foregroundStyle(Ink.primary)
                        Spacer(minLength: Spacing.base)
                        Toggle("", isOn: Binding(
                            get: { isPrivate },
                            set: { makePrivate in
                                Task {
                                    let admin = model.permissionGate.permissions(inGuild: guildID)
                                        .contains(.administrator)
                                    await store.setChannelPrivate(
                                        channel,
                                        isPrivate: makePrivate,
                                        keepingAccessFor: admin ? nil : model.currentUserID
                                    )
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(SettingsSurface.switchOn)
                        .accessibilityLabel(Text(isCategory ? "Private Category" : "Private Channel"))
                    }
                    Text(privacyDetail)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(SettingsMetrics.cardContentInset)
            }
            if everyoneIsAdmin {
                SettingsFootnote(
                    "All members can view this channel because @everyone has Administrator permissions. You can change this in Roles via Server Settings.",
                    symbolName: "exclamationmark.triangle.fill"
                )
            } else if !everyoneCanView && !isPrivate {
                SettingsFootnote(
                    "Heads up, @everyone does not have permission to view or connect to channels in this server. All channels will be default hidden to members. Use the Advanced View to give specific roles or members access to this channel.",
                    symbolName: "exclamationmark.triangle.fill"
                )
            }
        }
        if isPrivate {
            accessList
        }
    }

    private var privacyDetail: String {
        switch channel.kind {
        case .category:
            "By making a category private, only select members and roles will be able to view this category. Linked channels in this category will automatically match to this setting."
        case .voice:
            "By making a channel private, only select members and roles will have access to view or connect to this channel."
        default:
            "By making a channel private, only select members and roles will be able to view this channel."
        }
    }

    // MARK: Who can access

    /// The roles and members an overwrite lets in, and the roles that are
    /// in regardless because they hold Administrator.
    private var accessList: some View {
        let access = ChannelAccess.permissions(for: channel.kind)
        let roles = model.roles[guildID] ?? [:]
        let admitted = channel.overwrites.filter { $0.id != guildID.rawValue && $0.allow.isSuperset(of: access) }
        let roleRows = admitted.filter { $0.subject == .role }.compactMap { roles[RoleID(rawValue: $0.id)] }
            .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
        let administrators = roles.values
            .filter { $0.permissions.contains(.administrator) && $0.id.rawValue != guildID.rawValue }
            .filter { role in !roleRows.contains { $0.id == role.id } }
            .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
        let memberRows = admitted.filter { $0.subject == .member }
        return SettingsGroup(isCategory ? "Who can access this category?" : "Who can access this channel?") {
            SettingsCard {
                AccessAddRow(store: store, model: model, channel: channel)
                ForEach(administrators, id: \.id) { role in
                    CardDivider()
                    accessRow(name: role.name, dot: model.roleDotColor(role), subject: nil)
                }
                ForEach(roleRows, id: \.id) { role in
                    CardDivider()
                    accessRow(
                        name: role.name,
                        dot: model.roleDotColor(role),
                        subject: Subject(id: role.id.rawValue, kind: .role, name: role.name)
                    )
                }
                ForEach(memberRows, id: \.id) { overwrite in
                    let name = model.users[UserID(rawValue: overwrite.id)]?.preferredName ?? String(overwrite.id)
                    CardDivider()
                    accessRow(name: name, dot: nil, subject: Subject(id: overwrite.id, kind: .member, name: name))
                }
            }
        }
    }

    private func accessRow(name: String, dot: Color?, subject: Subject?) -> some View {
        ObjectRow(title: name, subtitle: subject == nil ? "Administrator" : nil) {
            Group {
                if let dot {
                    Circle().fill(dot).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .frame(width: 28, height: 28)
        } trailing: {
            if let subject {
                RowIconButton(symbolName: "xmark", label: "Remove", role: .destructive) {
                    removing = subject
                }
            }
        }
    }
}

/// "Add members or roles": a role or a member, let into a private channel.
private struct AccessAddRow: View {
    let store: ServerSettingsStore
    let model: AppModel
    let channel: Channel

    @State private var isPicking = false

    var body: some View {
        SettingsActionRow("Add members or roles", help: nil, actionTitle: "Add") {
            isPicking = true
        }
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            SubjectPicker(model: model, channel: channel) { id, kind in
                isPicking = false
                let access = ChannelAccess.permissions(for: channel.kind)
                var overwrite = channel.overwrites.first { $0.id == id }
                    ?? PermissionOverwrite(id: id, subject: kind, allow: [], deny: [])
                overwrite.allow.formUnion(access)
                overwrite.deny.subtract(access)
                Task { await store.saveOverwrite(overwrite, in: channel.id) }
            }
        }
    }
}

/// Roles and members not already on a channel, searchable — Discord's
/// "Add:" picker.
struct SubjectPicker: View {
    let model: AppModel
    let channel: Channel
    var pick: (UInt64, PermissionOverwrite.Subject) -> Void

    @State private var query = ""

    var body: some View {
        let guildID = channel.guildID ?? GuildID(rawValue: 0)
        let present = Set(channel.overwrites.map(\.id))
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let roles = (model.roles[guildID] ?? [:]).values
            .filter { !present.contains($0.id.rawValue) && $0.id.rawValue != guildID.rawValue }
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
        let members = (model.members[guildID] ?? [:]).keys
            .filter { !present.contains($0.rawValue) }
            .compactMap { model.users[$0] }
            .filter { needle.isEmpty || $0.preferredName.lowercased().contains(needle) || $0.username.lowercased().contains(needle) }
            .sorted { $0.preferredName.localizedCaseInsensitiveCompare($1.preferredName) == .orderedAscending }
            .prefix(50)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Role/Member", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .padding(.horizontal, Spacing.snug)
                .frame(height: FlyoutMetrics.rowHeight)
            FlyoutDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !roles.isEmpty {
                        header("Roles")
                        ForEach(roles, id: \.id) { role in
                            FlyoutRow(title: role.name, dotColor: model.roleDotColor(role)) {
                                pick(role.id.rawValue, .role)
                            }
                        }
                    }
                    if !members.isEmpty {
                        header("Members")
                        ForEach(Array(members), id: \.id) { user in
                            FlyoutRow(title: user.preferredName, subtitle: user.username, symbolName: "person") {
                                pick(user.id.rawValue, .member)
                            }
                        }
                    }
                }
                .padding(.bottom, Spacing.tight)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Spacing.tight)
        .frame(width: 260)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(Ink.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.tight)
    }
}

// MARK: - Advanced permissions

/// Every overwrite on the channel, and the three-way switch for each
/// permission — edited as a draft, saved together.
private struct AdvancedPermissionsEditor: View {
    let store: ServerSettingsStore
    let model: AppModel
    let channel: Channel

    @State private var isExpanded = true
    @State private var selection: UInt64?
    /// Overwrites as edited, keyed by subject; absent is "as the channel has it".
    @State private var drafts: [UInt64: PermissionOverwrite] = [:]
    @State private var isAdding = false

    private var guildID: GuildID { channel.guildID ?? GuildID(rawValue: 0) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack(alignment: .top, spacing: Spacing.margin) {
                subjects
                    .frame(width: 200)
                editor
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, Spacing.snug)
            if !changed.isEmpty {
                UnsavedChangesBar(
                    reset: { drafts = [:] },
                    save: save
                )
                .padding(.top, Spacing.snug)
            }
        } label: {
            Text("Advanced permissions")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
        }
        .onChange(of: channel.overwrites) {
            // What was saved is now the channel's; what was not stays a draft.
            drafts = drafts.filter { id, draft in channel.overwrites.first { $0.id == id } != draft }
        }
    }

    /// The overwrites as they stand with the draft applied — `@everyone`
    /// always present, roles in the server's order, then members.
    private var overwrites: [PermissionOverwrite] {
        var byID = Dictionary(uniqueKeysWithValues: channel.overwrites.map { ($0.id, $0) })
        for (id, draft) in drafts { byID[id] = draft }
        if byID[guildID.rawValue] == nil {
            byID[guildID.rawValue] = PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [], deny: [])
        }
        let roles = model.roles[guildID] ?? [:]
        let roleRows = byID.values.filter { $0.subject == .role }.sorted { lhs, rhs in
            guard let a = roles[RoleID(rawValue: lhs.id)], let b = roles[RoleID(rawValue: rhs.id)] else {
                return lhs.id < rhs.id
            }
            return RoleOrder.outranks(a, b, guildID: guildID)
        }
        let memberRows = byID.values.filter { $0.subject == .member }.sorted { $0.id < $1.id }
        return roleRows + memberRows
    }

    private var changed: [PermissionOverwrite] {
        drafts.values.filter { draft in channel.overwrites.first { $0.id == draft.id } != draft }
    }

    private var selected: PermissionOverwrite? {
        let id = selection ?? guildID.rawValue
        return overwrites.first { $0.id == id }
    }

    private var subjects: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Roles")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .textCase(.uppercase)
                Spacer()
                Button { isAdding = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
                .help("Add:")
                .accessibilityLabel(Text("Add members or roles"))
                .popover(isPresented: $isAdding, arrowEdge: .trailing) {
                    SubjectPicker(model: model, channel: channelWithDrafts) { id, kind in
                        isAdding = false
                        drafts[id] = PermissionOverwrite(id: id, subject: kind, allow: [], deny: [])
                        selection = id
                    }
                }
            }
            .padding(.bottom, Spacing.tight)
            ForEach(overwrites, id: \.id) { overwrite in
                let isSelected = overwrite.id == (selection ?? guildID.rawValue)
                Button { selection = overwrite.id } label: {
                    HStack(spacing: Spacing.tight) {
                        subjectMark(overwrite)
                        Text(verbatim: name(of: overwrite))
                            .font(SettingsType.rowTitle)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.base)
                    .frame(height: 30)
                    .background(
                        isSelected ? SettingsSurface.controlTrough : .clear,
                        in: .settingsRect(6)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// The channel as the picker should see it: drafted subjects count as present.
    private var channelWithDrafts: Channel {
        var copy = channel
        copy.overwrites = overwrites
        return copy
    }

    @ViewBuilder
    private func subjectMark(_ overwrite: PermissionOverwrite) -> some View {
        if overwrite.subject == .role, let role = model.roles[guildID]?[RoleID(rawValue: overwrite.id)] {
            Circle().fill(model.roleDotColor(role)).frame(width: 10, height: 10)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundStyle(Ink.secondary)
        }
    }

    private func name(of overwrite: PermissionOverwrite) -> String {
        if overwrite.id == guildID.rawValue { return "@everyone" }
        switch overwrite.subject {
        case .role: return model.roles[guildID]?[RoleID(rawValue: overwrite.id)]?.name ?? String(overwrite.id)
        case .member: return model.users[UserID(rawValue: overwrite.id)]?.preferredName ?? String(overwrite.id)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let overwrite = selected {
            let isEveryone = overwrite.id == guildID.rawValue
            VStack(alignment: .leading, spacing: Spacing.margin) {
                ForEach(ChannelPermissionCatalog.sections(for: channel.kind, isEveryone: isEveryone)) { section in
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text(section.title)
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(Ink.tertiary)
                            .textCase(.uppercase)
                        SettingsCard {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { CardDivider() }
                                PermissionSwitchRow(
                                    entry: entry,
                                    state: overwrite.state(of: entry.permission)
                                ) { state in
                                    var edited = overwrite
                                    edited.set(state, for: entry.permission)
                                    drafts[overwrite.id] = edited
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func save() {
        let pending = changed
        drafts = [:]
        Task {
            for overwrite in pending {
                await store.saveOverwrite(overwrite, in: channel.id)
            }
        }
    }
}

/// One permission and Discord's three-way switch: Deny, Passthrough, Allow.
private struct PermissionSwitchRow: View {
    var entry: ChannelPermissionCatalog.Entry
    var state: OverwriteState
    var set: (OverwriteState) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                Text(entry.detail)
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.base)
            HStack(spacing: 0) {
                cell(.deny, symbol: "xmark", tint: Palette.destructive, label: "Deny")
                cell(.inherit, symbol: "slash.circle", tint: Ink.tertiary, label: "Passthrough")
                cell(.allow, symbol: "checkmark", tint: Palette.affirmative, label: "Allow")
            }
            .background(SettingsSurface.controlTrough, in: .settingsRect(6))
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.base)
    }

    private func cell(_ value: OverwriteState, symbol: String, tint: some ShapeStyle, label: String) -> some View {
        let isOn = state == value
        return Button { set(value) } label: {
            Image(symbol: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 24)
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.tertiary))
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(AnyShapeStyle(tint))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
