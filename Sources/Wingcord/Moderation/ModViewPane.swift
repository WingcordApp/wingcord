import SwiftUI
import WingcordCore

/// Mod View (`94c16fc4`): a moderator's look at one person, beside the
/// conversation or the Members page.
///
/// **Discord's Info panel, in its order**: who they are and the five acts,
/// then Signals, Server Activity, Mod Permissions, Roles and Account — each
/// section only where it has something to say. Server Activity's rows lead
/// out: the message counts to the search panel, which shows over this column
/// until it closes, and the Audit Log count to the panel of what was done to
/// them. Mod Permissions' "All" opens every permission they hold and what
/// grants it.
struct ModViewPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let store = model.modView {
                header(store)
                Divider().overlay(Ink.quaternary)
                switch store.panel {
                case .info:
                    ScrollView {
                        ModViewInfo(store: store)
                            .padding(Spacing.margin)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                case .permissions:
                    ModViewPermissions(store: store)
                case .auditLog:
                    ModViewAuditLog(store: store)
                }
            }
        }
        .frame(width: Proportions.searchColumnIdeal)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(motion.standard, value: model.modView?.panel)
        .onExitCommand { model.closeModView() }
    }

    private func header(_ store: ModViewStore) -> some View {
        HStack(spacing: Spacing.base) {
            if store.panel != .info {
                Button { store.panel = .info } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(Ink.secondary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back"))
            }
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Text(title(store.panel))
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: 0)
            Button { store.refresh() } label: {
                Group {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh")
            .accessibilityLabel(Text("Refresh"))
            Button { model.closeModView() } label: {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close Mod View"))
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
    }

    private func title(_ panel: ModViewStore.Panel) -> String {
        switch panel {
        case .info: "Mod View"
        case .permissions: "All Granted Permissions"
        case .auditLog: "Moderator Action Log"
        }
    }
}

// MARK: - Info

private struct ModViewInfo: View {
    var store: ModViewStore

    @Environment(AppModel.self) private var model

    var body: some View {
        let userID = store.userID
        let guildID = store.guildID
        let member = model.members[guildID]?[userID]
        VStack(alignment: .leading, spacing: Spacing.group) {
            identity(member: member)
            actions(member: member)
            if member == nil {
                Callout(
                    text: "User is no longer a member of this server.",
                    symbolName: "person.crop.circle.badge.xmark",
                    tint: Palette.destructive
                )
            }
            if let member {
                signals(member)
            }
            serverActivity
            if let member {
                modPermissions(member)
                roles(member)
            }
            account(member: member)
        }
    }

    // MARK: Who

    private func identity(member: Member?) -> some View {
        let user = model.users[store.userID]
        return Button {
            model.openProfile(store.userID, anchor: .zero, depth: .full)
        } label: {
            HStack(spacing: Spacing.snug) {
                AvatarView(
                    url: model.avatarURL(forUserID: store.userID, inGuild: store.guildID, side: 48),
                    monogram: String(user?.preferredName.prefix(1) ?? "?"),
                    side: 48
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.moderationName(of: store.userID, in: store.guildID))
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(verbatim: user?.handle ?? "")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens their profile"))
    }

    /// Message, Kick, Ban, Timeout and Copy ID — Discord's five, each held
    /// where the reader may not, never hidden.
    private func actions(member: Member?) -> some View {
        let userID = store.userID
        let guildID = store.guildID
        let moderation = model.moderationActions(for: userID, in: guildID)
        let isSelf = userID == model.currentUserID
        return HStack(spacing: Spacing.base) {
            ModViewAction(title: "Message", symbolName: "bubble.left.fill", isEnabled: !isSelf) {
                model.messagePerson(userID)
            }
            if member != nil {
                ModViewAction(title: "Kick", symbolName: "person.fill.xmark", isEnabled: moderation.canKick) {
                    model.presentModeration(.kick(userID, guildID))
                }
            }
            ModViewAction(title: "Ban", symbolName: "hammer.fill", isEnabled: moderation.canBan) {
                model.presentModeration(.ban(userID, guildID))
            }
            if member != nil {
                ModViewAction(
                    title: moderation.isTimedOut ? "Remove" : "Timeout",
                    symbolName: "clock.fill",
                    isEnabled: moderation.canTimeout
                ) {
                    model.presentModeration(moderation.isTimedOut
                        ? .removeTimeout(userID, guildID)
                        : .timeout(userID, guildID))
                }
            }
            ModViewAction(title: "Copy ID", symbolName: "doc.on.doc.fill", isEnabled: true) {
                AppModel.copy(userID.description)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func signals(_ member: Member) -> some View {
        let unusualDM = member.unusualDMActivityUntil
        let timedOut = member.communicationDisabledUntil.flatMap { $0 > .now ? $0 : nil }
        if unusualDM != nil || timedOut != nil {
            ModViewSection("Signals") {
                if let unusualDM {
                    ModViewRow(symbolName: "exclamationmark.bubble", title: "Unusual DM Activity") {
                        Text(unusualDM, format: .relative(presentation: .named))
                    }
                }
                if let timedOut {
                    ModViewRow(symbolName: "clock", title: "Timed Out") {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: TimeoutCountdown.text(until: timedOut, now: context.date))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var serverActivity: some View {
        let counts = store.counts
        let audits = store.auditGroups
        return ModViewSection("Server Activity") {
            countRow("Messages", symbolName: "bubble.left", count: counts?.messages) {
                model.searchModViewHistory(nil)
            }
            countRow("Links", symbolName: "link", count: counts?.links) {
                model.searchModViewHistory(.link)
            }
            countRow("Media", symbolName: "photo", count: counts?.media) {
                model.searchModViewHistory(.file)
            }
            ModViewRow(
                symbolName: "list.bullet.rectangle",
                title: "Audit Log",
                open: (audits?.isEmpty == false) ? { store.panel = .auditLog } : nil
            ) {
                if store.auditFailed {
                    Text("This is Awkward").foregroundStyle(Palette.destructive)
                } else if let audits {
                    Text(audits.count.formatted())
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func countRow(
        _ title: String,
        symbolName: String,
        count: Int?,
        open: @escaping () -> Void
    ) -> some View {
        ModViewRow(symbolName: symbolName, title: title, open: (count ?? 0) > 0 ? open : nil) {
            if let count {
                Text(count.formatted())
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func modPermissions(_ member: Member) -> some View {
        let permissions = model.memberPermissions(of: store.userID, in: store.guildID)
        let held = ModPermissions.held(permissions)
        let total = ModPermissions.granted(permissions).count
        return VStack(alignment: .leading, spacing: Spacing.base) {
            HStack {
                Text("Mod Permissions")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer()
                Button { store.panel = .permissions } label: {
                    HStack(spacing: 2) {
                        Text("All (\(total))")
                            .font(.system(.caption, weight: .semibold))
                            .textCase(.uppercase)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Ink.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            ModViewGroup {
                if held.isEmpty {
                    Text("No Mod Permissions")
                        .font(.system(.subheadline))
                        .foregroundStyle(Palette.affirmative)
                        .padding(Spacing.snug)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    FlowLayout(spacing: Spacing.tight) {
                        ForEach(held) { entry in
                            ModPermissionChip(
                                title: entry.title,
                                isElevated: ModPermissions.elevated.contains(entry.permission)
                            )
                        }
                    }
                    .padding(Spacing.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func roles(_ member: Member) -> some View {
        let guildRoles = model.roles[store.guildID] ?? [:]
        let held = member.roleIDs
            .compactMap { guildRoles[$0] }
            .filter { $0.id.rawValue != store.guildID.rawValue }
            .sorted { RoleOrder.outranks($0, $1, guildID: store.guildID) }
            .map(model.profileRole)
        let editing = model.roleEditing(for: store.userID, in: store.guildID)
        return ModViewSection("Roles") {
            Group {
                if held.isEmpty && editing?.addable.isEmpty != false {
                    Text("No Roles")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                } else {
                    RoleChipFlow(roles: held, size: .compact, editing: editing)
                }
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func account(member: Member?) -> some View {
        let guild = model.guilds[store.guildID]
        let gated = guild?.features.contains("MEMBER_VERIFICATION_GATE_ENABLED") ?? false
        return ModViewSection("Account") {
            if let member {
                // Discord's test (`te`): a member who joined has passed the
                // server's verification level, whatever it is now.
                ModViewRow(symbolName: "checkmark.shield", title: "Passed Verification Level") {
                    check(member.joinedAt != nil || member.flags.contains(.bypassesVerification))
                }
                if gated {
                    ModViewRow(symbolName: "doc.text", title: "Agreed to Rules") {
                        check(member.flags.contains(.bypassesVerification)
                            || member.flags.contains(.completedOnboarding)
                            || !member.isPending)
                    }
                }
            }
            ModViewRow(symbolName: "calendar", title: "Discord Join Date") {
                Text(store.userID.timestamp.formatted(date: .abbreviated, time: .omitted))
            }
            if let member {
                if let joined = member.joinedAt {
                    ModViewRow(symbolName: "person.badge.clock", title: "Server Join Date") {
                        Text(joined.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                ModViewRow(symbolName: "door.left.hand.open", title: "Join Method") {
                    joinMethod
                }
            }
        }
    }

    @ViewBuilder
    private var joinMethod: some View {
        if let source = store.joinSource {
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: source.title)
                if let inviter = source.inviterID {
                    Text(verbatim: "Invited by \(model.users[inviter]?.preferredName ?? inviter.description)")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                }
            }
        } else {
            Text("Join method not available")
                .foregroundStyle(Ink.tertiary)
        }
    }

    private func check(_ isOn: Bool) -> some View {
        Image(symbol: isOn ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(isOn ? Palette.affirmative : Palette.destructive)
            .accessibilityLabel(Text(isOn ? "Yes" : "No"))
    }
}

// MARK: - Permissions

/// Every permission they hold, and what grants each — Discord's Permissions
/// panel, with its search.
private struct ModViewPermissions: View {
    var store: ModViewStore

    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let permissions = model.memberPermissions(of: store.userID, in: store.guildID)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = ModPermissions.granted(permissions).filter {
            needle.isEmpty || $0.title.lowercased().contains(needle) || $0.detail.lowercased().contains(needle)
        }
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search permission names, category, or description...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.composerControlHeight)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
                .padding(Spacing.margin)
            if entries.isEmpty {
                Text("No permissions found")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, Spacing.margin)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.base) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, Spacing.margin)
                    .padding(.bottom, Spacing.margin)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func row(_ entry: PermissionCatalog.Entry) -> some View {
        let sources = model.permissionSources(of: entry.permission, for: store.userID, in: store.guildID)
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                if ModPermissions.elevated.contains(entry.permission) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .help("Elevated permissions grant higher levels of access to server settings, and should only be granted to highly trusted mods.")
                }
                Text(entry.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
            }
            Text("Permission Granted By These Roles")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .textCase(.uppercase)
            FlowLayout(spacing: Spacing.tight) {
                if sources.grantsOwnership {
                    ModPermissionChip(title: "Server Owner", isElevated: false)
                }
                ForEach(sources.roles, id: \.id) { role in
                    RoleChip(role: model.profileRole(role), size: .compact, remove: nil)
                }
            }
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.chip))
    }
}

// MARK: - Audit log

/// What was done to them, merged the way Discord merges a run of entries.
private struct ModViewAuditLog: View {
    var store: ModViewStore

    var body: some View {
        if let groups = store.auditGroups, let page = store.auditPage {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach(groups) { group in
                        row(group, page: page)
                    }
                }
                .padding(Spacing.margin)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else if store.auditFailed {
            Text("We broke something. Come back later.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
                .padding(Spacing.margin)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(Spacing.margin)
        }
    }

    private func row(_ group: AuditLogMerge.Group, page: AuditLogPage) -> some View {
        let entry = group.entry
        let actor = entry.userID.flatMap { page.users[$0] }
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                Image(symbol: entry.action.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(entry.action.isDestructive ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
                Text(verbatim: "\(actor?.displayName ?? actor?.username ?? "Discord") \(entry.action.sentence)")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.base)
                Text(group.ended, format: .relative(presentation: .named))
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
            }
            if let reason = entry.reason {
                Text(verbatim: "“\(reason)”")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
            }
            ForEach(Array(group.changes.prefix(8).enumerated()), id: \.offset) { _, change in
                Text(verbatim: describe(change))
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.chip))
    }

    private func describe(_ change: AuditLogEntry.Change) -> String {
        switch (change.before, change.after) {
        case (let before?, let after?): "\(change.title): \(before) → \(after)"
        case (nil, let after?): "\(change.title): \(after)"
        case (let before?, nil): "\(change.title) was \(before)"
        case (nil, nil): change.title
        }
    }
}

// MARK: - Parts

/// A titled group of rows, as Mod View lays its sections out.
private struct ModViewSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            ModViewGroup { content }
        }
    }
}

private struct ModViewGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.chip))
    }
}

/// One fact in a section: a glyph, its name, and its value — a button where
/// it leads somewhere.
private struct ModViewRow<Value: View>: View {
    var symbolName: String
    var title: String
    var open: (() -> Void)?
    @ViewBuilder var value: Value

    init(
        symbolName: String,
        title: String,
        open: (() -> Void)? = nil,
        @ViewBuilder value: () -> Value
    ) {
        self.symbolName = symbolName
        self.title = title
        self.open = open
        self.value = value()
    }

    var body: some View {
        let label = HStack(spacing: Spacing.base) {
            Image(symbol: symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Spacing.base)
            value
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.secondary)
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(minHeight: 36)
        .contentShape(.rect)

        if let open {
            Button(action: open) { label }
                .buttonStyle(.plain)
        } else {
            label
                .accessibilityElement(children: .combine)
        }
    }
}

/// One of Mod View's five acts: a square with a glyph, its name as the tip.
private struct ModViewAction: View {
    var title: String
    var symbolName: String
    var isEnabled: Bool
    var act: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: act) {
            Image(symbol: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    isHovering && isEnabled ? Palette.hoverFill : Palette.groupedFill,
                    in: .rect(cornerRadius: Radius.chip)
                )
                .contentShape(.rect(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.quaternary))
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(Text(title))
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
    }
}

/// A permission's name as Mod View lists it, marked where it is elevated.
private struct ModPermissionChip: View {
    var title: String
    var isElevated: Bool

    var body: some View {
        HStack(spacing: 3) {
            if isElevated {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            Text(title)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: 7))
    }
}
