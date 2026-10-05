import SwiftUI
import WingcordCore

/// The Members page — Discord's member-safety table (`cb3be506`), for
/// moderators.
///
/// **Discord's columns, filters and words.** Name, Member Since, Joined
/// Discord, Join Method (with Manage Server), Roles and Signals; every header
/// but Name opens its filter, and the filters are the search's own facets
/// (`MemberSearchQuery`), so what the table shows is what Discord's index
/// answered rather than a page filtered after the fact.
///
/// **A row opens the person's profile; its shield opens Mod View; its ⋯ and a
/// right-click open the person menu** — Discord's three, in Discord's places.
struct MembersPageContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let store = model.memberSafety, store.guildID == model.selectedGuildID {
            MembersPage(store: store)
                .task(id: store.guildID) { store.start() }
        } else {
            SurfaceLoadingState(message: "Loading members…")
        }
    }
}

private struct MembersPage: View {
    var store: MemberSafetyStore

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var text = ""

    var body: some View {
        let guildID = store.guildID
        let permissions = model.permissionGate.permissions(inGuild: guildID)
        let columns = MemberColumns(
            selects: ModerationPolicy.canBulkBan(permissions),
            showsJoinMethod: permissions.contains(.manageGuild)
        )
        let reviewsApplications = model.reviewsApplications(in: guildID)
        // **Sideways, as Discord's is** (`999192`'s `horizontalScroller`): a
        // page narrower than its columns — beside Mod View, say — scrolls
        // rather than pushing the table past the window. The page is at least
        // as wide as what is visible, so a wide window still fills.
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    if reviewsApplications {
                        tabs
                    }
                    switch store.tab {
                    case .members:
                        toolbar(permissions: permissions)
                        if !store.selection.isEmpty {
                            selectionBar
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        MembersTableHeader(store: store, columns: columns)
                        Divider().overlay(Ink.quaternary)
                        content(columns: columns)
                        if store.phase == .loaded, store.total > 0 {
                            Divider().overlay(Ink.quaternary)
                            MembersPager(store: store)
                        }
                    case .applications(let status):
                        // What is visible, not its widest answer on one line:
                        // its rows wrap.
                        ApplicationsList(store: store, status: status)
                            .frame(width: proxy.size.width)
                    }
                }
                .frame(minWidth: proxy.size.width, maxHeight: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .animation(motion.standard, value: store.selection.isEmpty)
        // Pending is asked for up front, so its tab can carry the count.
        .task(id: reviewsApplications) {
            if reviewsApplications { store.prefetch(.submitted) }
        }
        // Discord searches 300 ms after the last keystroke.
        .task(id: text) {
            guard text != store.query.text else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            var next = store.query
            next.text = text
            store.apply(next)
        }
    }

    // MARK: Above the table

    /// Discord's tabs: All Members, then the applications by status.
    private var tabs: some View {
        let pending = store.applications[.submitted]?.count ?? 0
        let options: [SegmentedPicker<MemberSafetyStore.Tab>.Option] = [
            .init(.members, "All Members"),
            .init(.applications(.submitted), pending > 0 ? "Pending (\(pending))" : "Pending"),
            .init(.applications(.rejected), "Rejected"),
            .init(.applications(.approved), "Approved"),
        ]
        return SegmentedPicker(
            options: options,
            selection: Binding(get: { store.tab }, set: { store.show($0) })
        )
        .fixedSize()
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.snug)
        .accessibilityLabel(Text("Member Applications"))
    }

    private func toolbar(permissions: Permissions) -> some View {
        let guild = model.guilds[store.guildID]
        let canPrune = guild.map {
            ModerationPolicy.canPrune(
                permissions,
                isOwner: $0.ownerID == model.currentUserID,
                features: $0.features
            )
        } ?? false
        return HStack(spacing: Spacing.snug) {
            Text(store.title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Spacing.base)
            HStack(spacing: Spacing.tight) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                TextField("Search by username or id", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline))
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(width: 240, height: Metrics.composerControlHeight)
            .background(Palette.surfaceRaised, in: .capsule)
            MembersSortButton(store: store)
            if canPrune {
                Button { model.presentModeration(.prune(store.guildID)) } label: {
                    Text("Prune")
                        .font(.system(.subheadline, weight: .semibold))
                        .padding(.horizontal, Spacing.snug)
                        .frame(height: Metrics.composerControlHeight)
                        .background(Palette.surfaceRaised, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.primary)
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.snug)
    }

    private var selectionBar: some View {
        let count = store.selection.count
        return HStack(spacing: Spacing.snug) {
            Text(count == 1 ? "1 member selected" : "\(count) members selected")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Button("Clear selection") { store.selection = [] }
                .buttonStyle(.link)
                .font(.system(.subheadline))
            Spacer()
            Button {
                model.presentModeration(.bulkBan(Array(store.selection), store.guildID))
            } label: {
                Text("Ban Members")
                    .font(.system(.subheadline, weight: .semibold))
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: Metrics.composerControlHeight)
                    .background(Palette.destructive, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.base)
        .background(Palette.groupedFill)
    }

    // MARK: The table

    @ViewBuilder
    private func content(columns: MemberColumns) -> some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .indexing:
            notice("Before searching, we need to index this server. Give us a bit.")
        case .failed(let reason):
            notice(reason)
        case .loaded:
            if store.total == 0 {
                notice("No members match these search results.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.pageRows) { row in
                            MemberTableRow(row: row, guildID: store.guildID, columns: columns, store: store)
                        }
                        if store.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                                .padding(Spacing.margin)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(.subheadline))
            .foregroundStyle(Ink.secondary)
            .multilineTextAlignment(.center)
            .padding(Spacing.group)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Which columns this reader's table has.
private struct MemberColumns: Equatable {
    /// The checkbox column — Bulk Ban's selection.
    var selects: Bool
    /// Join Method, which Discord shows only with Manage Server.
    var showsJoinMethod: Bool

    static let check: CGFloat = 28
    /// Name takes what the others leave, as Discord's `fillCol` does — and
    /// never less than this, which is where the page starts to scroll.
    static let name: CGFloat = 200
    static let date: CGFloat = 112
    static let joinMethod: CGFloat = 150
    static let roles: CGFloat = 170
    static let signals: CGFloat = 76
    static let actions: CGFloat = 64
}

// MARK: - Header

private struct MembersTableHeader: View {
    var store: MemberSafetyStore
    var columns: MemberColumns

    @Environment(AppModel.self) private var model

    var body: some View {
        let query = store.query
        HStack(spacing: Spacing.base) {
            if columns.selects {
                selectAll
                    .frame(width: MemberColumns.check)
            }
            label("Name")
                .frame(minWidth: MemberColumns.name, idealWidth: MemberColumns.name, maxWidth: .infinity, alignment: .leading)
            MembersFilterHeader(
                title: "Member Since",
                isFiltered: query.joined.isActive,
                isSorted: query.sort == .joinedOldest
            ) {
                DateRangeFilter(title: "Member Since Date Options", range: query.joined) { range in
                    var next = store.query
                    next.joined = range
                    store.apply(next)
                }
            }
            .frame(width: MemberColumns.date, alignment: .leading)
            MembersFilterHeader(
                title: "Joined Discord",
                isFiltered: query.accountCreated.isActive,
                isSorted: query.sort == .accountNewest || query.sort == .accountOldest
            ) {
                DateRangeFilter(title: "Discord Join Date Options", range: query.accountCreated) { range in
                    var next = store.query
                    next.accountCreated = range
                    store.apply(next)
                }
            }
            .frame(width: MemberColumns.date, alignment: .leading)
            if columns.showsJoinMethod {
                MembersFilterHeader(
                    title: "Join Method",
                    isFiltered: query.sourceInviteCode?.isEmpty == false || query.joinSourceType != nil,
                    isSorted: false
                ) {
                    JoinMethodFilter(store: store)
                }
                .frame(width: MemberColumns.joinMethod, alignment: .leading)
            }
            MembersFilterHeader(title: "Roles", isFiltered: !query.roleIDs.isEmpty, isSorted: false) {
                RoleFilter(store: store)
            }
            .frame(width: MemberColumns.roles, alignment: .leading)
            MembersFilterHeader(title: "Signals", isFiltered: query.filtersSignals, isSorted: false) {
                SignalsFilter(store: store)
            }
            .help("Filter based on safety info, such as timed out or engaging in unusual DM activity.")
            .frame(width: MemberColumns.signals, alignment: .leading)
            Color.clear.frame(width: MemberColumns.actions, height: 1)
        }
        .padding(.horizontal, Spacing.group)
        .frame(height: 32)
    }

    /// Ticks every member on the page the reader may ban — or clears them, when
    /// all are ticked. Discord's header checkbox.
    private var selectAll: some View {
        let actionable = store.pageRows
            .map(\.id)
            .filter { model.moderationActions(for: $0, in: store.guildID).canBan }
        let isAll = !actionable.isEmpty && actionable.allSatisfy { store.selection.contains($0) }
        return Button {
            if isAll {
                store.selection.subtract(actionable)
            } else {
                store.selection.formUnion(actionable)
            }
        } label: {
            Image(symbol: isAll ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(isAll ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
        }
        .buttonStyle(.plain)
        .disabled(actionable.isEmpty)
        .help(actionable.isEmpty ? "There are no actionable members" : "")
        .accessibilityLabel(Text("Select all"))
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(Ink.tertiary)
            .textCase(.uppercase)
    }
}

/// A column header that opens its filter: Discord's eyebrow label and funnel,
/// lit while the filter narrows anything and in the accent while the table is
/// sorted by it.
private struct MembersFilterHeader<Filter: View>: View {
    var title: String
    var isFiltered: Bool
    var isSorted: Bool
    @ViewBuilder var filter: Filter

    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .textCase(.uppercase)
                    .lineLimit(1)
                Image(symbol: isFiltered
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
            }
            .foregroundStyle(
                isSorted ? AnyShapeStyle(Palette.accent)
                    : isFiltered ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.tertiary)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            filter
        }
    }
}

// MARK: - Filters

/// Member Since and Joined Discord: Discord's presets, and a custom range.
private struct DateRangeFilter: View {
    var title: String
    var range: DateRange
    var apply: (DateRange) -> Void

    @State private var after = Date.now.addingTimeInterval(-7 * 86400)
    @State private var before = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.tight)
            ForEach(DateRange.Preset.allCases) { preset in
                FlyoutRow(title: preset.title, accessory: .tick(range.preset == preset)) {
                    if preset == .custom {
                        apply(DateRange(preset: .custom, after: after, before: before))
                    } else {
                        apply(.preset(preset))
                    }
                }
            }
            if range.preset == .custom {
                FlyoutDivider()
                VStack(alignment: .leading, spacing: Spacing.base) {
                    DatePicker("After Date", selection: $after, displayedComponents: .date)
                    DatePicker("Before Date", selection: $before, displayedComponents: .date)
                }
                .font(.system(.subheadline))
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.base)
                .onChange(of: after) { apply(DateRange(preset: .custom, after: after, before: before)) }
                .onChange(of: before) { apply(DateRange(preset: .custom, after: after, before: before)) }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 240)
        .onAppear {
            if let start = range.after { after = start }
            if let end = range.before { before = end }
        }
    }
}

/// Join Method: one way in, or one invite's code.
private struct JoinMethodFilter: View {
    var store: MemberSafetyStore

    @State private var code = ""

    private static let sources: [(Int, String)] = [
        (5, "Server Invite"), (6, "Vanity URL"), (1, "Bot Invite"), (2, "Integration"),
        (3, "Server Discovery"), (4, "Student Hub"), (7, "Manual Verification"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Invite code", text: $code)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .padding(.horizontal, Spacing.snug)
                .frame(height: FlyoutMetrics.rowHeight)
                .onSubmit {
                    var next = store.query
                    let trimmed = code.trimmingCharacters(in: .whitespaces)
                    next.sourceInviteCode = trimmed.isEmpty ? nil : trimmed
                    store.apply(next)
                }
            FlyoutDivider()
            FlyoutRow(title: "All", accessory: .tick(store.query.joinSourceType == nil)) {
                var next = store.query
                next.joinSourceType = nil
                store.apply(next)
            }
            ForEach(Self.sources, id: \.0) { source in
                FlyoutRow(title: source.1, accessory: .tick(store.query.joinSourceType == source.0)) {
                    var next = store.query
                    next.joinSourceType = source.0
                    store.apply(next)
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 240)
        .onAppear { code = store.query.sourceInviteCode ?? "" }
    }
}

/// Roles: any of these.
private struct RoleFilter: View {
    var store: MemberSafetyStore

    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let roles = (model.roles[store.guildID] ?? [:]).values
            .filter { $0.id.rawValue != store.guildID.rawValue }
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { RoleOrder.outranks($0, $1, guildID: store.guildID) }
        VStack(alignment: .leading, spacing: 0) {
            TextField("Select a role", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .padding(.horizontal, Spacing.snug)
                .frame(height: FlyoutMetrics.rowHeight)
            FlyoutDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(roles, id: \.id) { role in
                        FlyoutRow(
                            title: role.name,
                            dotColor: model.roleDotColor(role),
                            accessory: .checkbox(store.query.roleIDs.contains(role.id))
                        ) {
                            var next = store.query
                            if next.roleIDs.contains(role.id) {
                                next.roleIDs.remove(role.id)
                            } else {
                                next.roleIDs.insert(role.id)
                            }
                            store.apply(next)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 260)
    }
}

/// Signals: Discord's four member safety flags.
private struct SignalsFilter: View {
    var store: MemberSafetyStore

    var body: some View {
        let query = store.query
        VStack(alignment: .leading, spacing: 0) {
            Text("Member Safety Flags")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.tight)
            flag("Unusual DM Activity", isOn: query.requiresUnusualDMActivity) { $0.requiresUnusualDMActivity.toggle() }
            flag("Timed Out", isOn: query.requiresTimeout) { $0.requiresTimeout.toggle() }
            flag("Unusual Account Activity", isOn: query.requiresUnusualAccountActivity) {
                $0.requiresUnusualAccountActivity.toggle()
            }
            flag("Quarantined", isOn: query.requiresQuarantine) { $0.requiresQuarantine.toggle() }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 240)
    }

    private func flag(_ title: String, isOn: Bool, toggle: @escaping (inout MemberSearchQuery) -> Void) -> some View {
        FlyoutRow(title: title, accessory: .checkbox(isOn)) {
            var next = store.query
            toggle(&next)
            store.apply(next)
        }
    }
}

/// Discord's Sort button and its four orders.
private struct MembersSortButton: View {
    var store: MemberSafetyStore

    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text("Sort")
                    .font(.system(.subheadline, weight: .semibold))
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.composerControlHeight)
            .background(Palette.surfaceRaised, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.primary)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(GuildMemberRow.Sort.allCases) { sort in
                    FlyoutRow(title: sort.title, accessory: .tick(store.query.sort == sort)) {
                        var next = store.query
                        next.sort = sort
                        store.apply(next)
                        isOpen = false
                    }
                }
            }
            .padding(.vertical, Spacing.tight)
            .frame(width: 260)
        }
    }
}

// MARK: - A row

private struct MemberTableRow: View {
    var row: GuildMemberRow
    var guildID: GuildID
    var columns: MemberColumns
    var store: MemberSafetyStore

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var menuAnchor: CGRect = .zero

    var body: some View {
        let moderation = model.moderationActions(for: row.id, in: guildID)
        HStack(spacing: Spacing.base) {
            if columns.selects {
                checkbox(canBan: moderation.canBan)
                    .frame(width: MemberColumns.check)
            }
            name
                .frame(minWidth: MemberColumns.name, idealWidth: MemberColumns.name, maxWidth: .infinity, alignment: .leading)
            dateCell(row.joinedAt)
                .frame(width: MemberColumns.date, alignment: .leading)
            dateCell(row.id.timestamp)
                .frame(width: MemberColumns.date, alignment: .leading)
            if columns.showsJoinMethod {
                joinMethod
                    .frame(width: MemberColumns.joinMethod, alignment: .leading)
            }
            roles
                .frame(width: MemberColumns.roles, alignment: .leading)
            signals
                .frame(width: MemberColumns.signals, alignment: .leading)
            actions(canOpenModView: moderation.canOpenModView)
                .frame(width: MemberColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.group)
        .frame(minHeight: 52)
        .background {
            if isHovering || store.selection.contains(row.id) {
                Rectangle().fill(Palette.hoverFill)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            model.openProfile(row.id, anchor: .zero, depth: .full)
        }
        .onSecondaryClick { rect in
            model.openUserMenu(for: row.id, anchor: rect, inGuild: guildID)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
    }

    private func checkbox(canBan: Bool) -> some View {
        let isOn = store.selection.contains(row.id)
        return Button {
            if isOn { store.selection.remove(row.id) } else { store.selection.insert(row.id) }
        } label: {
            Image(symbol: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
        }
        .buttonStyle(.plain)
        .disabled(!canBan)
        .help(canBan ? "" : "Cannot action this member")
        .accessibilityLabel(Text("Select \(row.name)"))
    }

    private var name: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: avatarURL, monogram: String(row.name.prefix(1)), side: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(verbatim: row.tag)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var avatarURL: URL? {
        if let hash = row.guildAvatarHash {
            return CDN.guildMemberAvatar(guildID: guildID, userID: row.id, hash: hash, side: 32)
        }
        return row.avatarHash.flatMap { CDN.avatar(userID: row.id, hash: $0, side: 32) }
    }

    @ViewBuilder
    private func dateCell(_ date: Date?) -> some View {
        if let date {
            Text(date, format: .relative(presentation: .named))
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .help(date.formatted(date: .long, time: .omitted))
        }
    }

    private var joinMethod: some View {
        let source = row.joinSource
        return HStack(spacing: 3) {
            if source.isLink {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(verbatim: source.title)
                .font(.system(.caption, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Palette.surfaceRaised, in: .capsule)
        .help(source.inviterID.map { "Invited by \(model.users[$0]?.preferredName ?? $0.description)" } ?? "")
    }

    private var roles: some View {
        let guildRoles = model.roles[guildID] ?? [:]
        let held = row.roleIDs
            .compactMap { guildRoles[$0] }
            .filter { $0.id.rawValue != guildID.rawValue }
            .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
        return HStack(spacing: Spacing.tight) {
            if let highest = held.first {
                RoleChip(role: model.profileRole(highest), size: .compact, remove: nil)
            }
            if held.count > 1 {
                Text("+\(held.count - 1)")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .monospacedDigit()
                    .help(held.dropFirst().map(\.name).joined(separator: ", "))
                    .accessibilityLabel(Text("View All Roles"))
            }
        }
    }

    private var signals: some View {
        HStack(spacing: Spacing.tight) {
            if row.hasUnusualDMActivity() {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(Ink.secondary)
                    .help("Sent excessive DMs to non-friend server members in last 24 hrs")
            }
            if let until = row.timedOutUntil, until > .now {
                Image(systemName: "clock.fill")
                    .foregroundStyle(Palette.destructive)
                    .help("Timed out for \(TimeoutCountdown.text(until: until))")
            }
            if row.isSpammer {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(Palette.destructive)
                    .help("Engaged in suspected spam activity")
            }
            if row.flags.isQuarantined {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(Ink.secondary)
                    .help("User can't talk in server until they change their member name")
            }
        }
        .font(.system(size: 14))
    }

    private func actions(canOpenModView: Bool) -> some View {
        HStack(spacing: Spacing.base) {
            Button {
                if canOpenModView {
                    model.openModView(for: row.id, in: guildID)
                } else {
                    model.openProfile(row.id, anchor: .zero, depth: .full)
                }
            } label: {
                Image(symbol: canOpenModView ? "shield.lefthalf.filled" : "person.fill")
                    .font(.system(size: 14))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .help(canOpenModView ? "Open Mod View" : "View Profile")
            Button {
                model.openUserMenu(for: row.id, anchor: menuAnchor, inGuild: guildID)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .help("More Options")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuAnchor = $0 }
        }
    }
}

// MARK: - Footer

/// "Showing [12] members of 2,345", and Discord's page buttons — seven at most.
private struct MembersPager: View {
    var store: MemberSafetyStore

    var body: some View {
        HStack(spacing: Spacing.base) {
            if store.total > MemberSafetyStore.pageSizes[0] {
                Text("Showing")
                    .foregroundStyle(Ink.secondary)
                FlyoutPicker(
                    selection: Binding(get: { store.pageSize }, set: { store.setPageSize($0) }),
                    options: MemberSafetyStore.pageSizes,
                    title: { $0.formatted() },
                    accessibilityTitle: "Members per page",
                    flyoutWidth: 120
                )
                Text("members of \(Text(store.total.formatted()).bold().foregroundStyle(Ink.primary))")
                    .foregroundStyle(Ink.secondary)
            } else {
                Text("Showing \(Text(store.total.formatted()).bold().foregroundStyle(Ink.primary)) \(store.total == 1 ? "member" : "members")")
                    .foregroundStyle(Ink.secondary)
            }
            Spacer()
            if store.pageCount > 1 {
                pages
            }
        }
        .font(.system(.subheadline))
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.base)
    }

    private var pages: some View {
        let count = store.pageCount
        let current = store.page
        let span = MemberSafetyStore.maximumVisiblePages
        let start = max(1, min(current - span / 2, count - span + 1))
        let end = min(count, start + span - 1)
        return HStack(spacing: 2) {
            pageButton(symbol: "chevron.left", target: current - 1, isEnabled: current > 1)
            ForEach(start...end, id: \.self) { page in
                Button { store.show(page: page) } label: {
                    Text(page.formatted())
                        .font(.system(.subheadline, weight: page == current ? .semibold : .regular))
                        .monospacedDigit()
                        .frame(minWidth: 26, minHeight: 26)
                        .background(page == current ? Palette.selectionFill : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(page == current ? Ink.primary : Ink.secondary)
            }
            pageButton(symbol: "chevron.right", target: current + 1, isEnabled: current < count)
        }
    }

    private func pageButton(symbol: String, target: Int, isEnabled: Bool) -> some View {
        Button { store.show(page: target) } label: {
            Image(symbol: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Ink.secondary : Ink.quaternary)
        .disabled(!isEnabled)
    }
}

// MARK: - Applications

/// One status's member applications — Discord's Pending, Rejected and Approved
/// tabs: who applied, when, what they answered, and on Pending, the verdict.
private struct ApplicationsList: View {
    var store: MemberSafetyStore
    var status: GuildJoinRequest.Status

    var body: some View {
        Group {
            if let requests = store.applications[status] {
                if requests.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.base) {
                            if let failure = store.applicationFailure {
                                Callout(text: failure, symbolName: "exclamationmark.triangle.fill", tint: Palette.destructive)
                            }
                            ForEach(requests) { request in
                                ApplicationRow(store: store, request: request)
                            }
                        }
                        .padding(Spacing.group)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else if let failure = store.applicationFailure {
                Text(verbatim: failure)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var empty: some View {
        let (title, detail) = switch status {
        case .submitted:
            ("There are no pending applications.", "You'll be able to manage new member applications here.")
        case .rejected:
            ("There are no rejected applications.", "You'll be able to view rejected applications here.")
        case .approved:
            ("There are no approved applications.", "You'll be able to view approved member applications here.")
        }
        return VStack(spacing: Spacing.tight) {
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
            Text(detail)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ApplicationRow: View {
    var store: MemberSafetyStore
    var request: GuildJoinRequest

    @Environment(AppModel.self) private var model
    @State private var isRejecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.snug) {
                AvatarView(
                    url: request.avatarHash.flatMap { CDN.avatar(userID: request.userID, hash: $0, side: 32) },
                    monogram: String((request.displayName ?? request.username).prefix(1)),
                    side: 32
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: request.displayName ?? request.username)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text(verbatim: request.username)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer(minLength: Spacing.base)
                if let applied = request.createdAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(request.status == .submitted ? "Applied" : "Reviewed")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(Ink.tertiary)
                            .textCase(.uppercase)
                        Text(applied, format: .relative(presentation: .named))
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                if request.status == .submitted {
                    verdicts
                }
            }
            ForEach(request.answers) { answer in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: answer.question)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                    Text(verbatim: answer.response)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            verdictLine
        }
        .padding(Spacing.snug)
        .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.chip))
        .sheet(isPresented: $isRejecting) {
            RejectApplicationSheet { reason in
                store.resolve(request, approve: false, reason: reason)
            }
        }
    }

    /// Discord's block under an application (`eh`, `eA`, `eE`): an interview
    /// under way on a pending one; on a judged one, the verdict, who gave it
    /// and when, the reason, and the way back into the interview.
    @ViewBuilder
    private var verdictLine: some View {
        let hasInterview = request.interviewChannelID.map { model.channelIndex[$0] != nil } ?? false
        switch request.status {
        case .submitted:
            if request.interviewChannelID != nil {
                HStack(spacing: Spacing.base) {
                    Label("Interview in Progress", systemImage: "hourglass")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.orange)
                    Spacer(minLength: Spacing.base)
                    interviewButton("Join Interview")
                }
            }
        case .approved, .rejected:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.status == .approved ? "Approved" : "Rejected")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(
                            request.status == .approved ? AnyShapeStyle(Palette.affirmative) : AnyShapeStyle(Ink.primary)
                        )
                    if let name = request.actionedByName, let when = request.actionedAt {
                        HStack(spacing: Spacing.tight) {
                            Text("By \(Text(verbatim: name).bold())")
                            Text(verbatim: "·")
                            Text(when, format: .dateTime.month(.wide).day().year())
                        }
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                    }
                    if request.status == .rejected, let reason = request.rejectionReason {
                        Text(verbatim: "Reason: \(reason)")
                            .font(.system(.caption))
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.base)
                // Discord offers the way back only to an interview this client
                // can open (`ej`'s channel test).
                if hasInterview { interviewButton("Open Interview") }
            }
        }
    }

    private func interviewButton(_ title: String) -> some View {
        Button { store.interview(request) } label: {
            Label(title, systemImage: "bubble.left.and.bubble.right")
                .font(.system(.subheadline, weight: .semibold))
                .padding(.horizontal, Spacing.snug)
                .frame(height: 28)
                .background(Palette.surfaceRaised, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.primary)
        .disabled(store.resolving.contains(request.id))
    }

    private var verdicts: some View {
        let isResolving = store.resolving.contains(request.id)
        return HStack(spacing: Spacing.tight) {
            // Discord's third act, while nobody has opened one yet (`em`).
            if request.interviewChannelID == nil {
                Button { store.interview(request) } label: {
                    Text("Interview")
                        .font(.system(.subheadline, weight: .semibold))
                        .padding(.horizontal, Spacing.snug)
                        .frame(height: 28)
                        .background(Palette.surfaceRaised, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.primary)
            }
            Button { isRejecting = true } label: {
                Text("Reject")
                    .font(.system(.subheadline, weight: .semibold))
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: 28)
                    .background(Palette.surfaceRaised, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.destructive)
            Button { store.resolve(request, approve: true) } label: {
                Text("Approve")
                    .font(.system(.subheadline, weight: .semibold))
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: 28)
                    .background(Palette.affirmative, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .disabled(isResolving)
        .opacity(isResolving ? 0.5 : 1)
    }
}

/// Discord's Reject (`867276`): an optional reason the applicant is shown,
/// up to 160 characters, then Reject.
private struct RejectApplicationSheet: View {
    var reject: (String?) -> Void

    @State private var reason = ""

    /// Discord's `maxLength`.
    private static let limit = 160

    var body: some View {
        FormSheet(
            title: "Provide a denial reason to the user (OPTIONAL)",
            confirmTitle: "Reject",
            isDestructive: true,
            closesOnConfirm: true,
            confirm: {
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                reject(trimmed.isEmpty ? nil : trimmed)
            }
        ) {
            TextField("", text: $reason, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .font(.system(.body))
                .padding(Spacing.snug)
                .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.chip, style: .continuous))
                .onChange(of: reason) { _, value in
                    guard value.count > Self.limit else { return }
                    reason = String(value.prefix(Self.limit))
                }
        }
    }
}
