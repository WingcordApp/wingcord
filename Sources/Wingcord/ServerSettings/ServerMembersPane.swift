import SwiftUI
import WingcordCore

// MARK: - Members
//
// Four tabs, and the split is not cosmetic: All Members comes from
// `members-search` and the other three from `requests?status=…`, which is a
// different route answering a different kind of thing. A member has a join date
// and roles; an applicant has answers and a verdict.
//
// **The applicant tabs are hidden where the server takes no applications.**
// Without a join form there is nothing on any of the three, ever — three empty
// tabs is three lies about a server that has never asked anybody a question.

struct MembersPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var sort: GuildMemberRow.Sort = .joinedNewest
    @State private var acting: GuildMemberRow?
    @State private var action: MemberAction = .kick

    private enum Tab: Hashable, Identifiable {
        case all
        case requests(GuildJoinRequest.Status)

        var id: String {
            switch self {
            case .all: "all"
            case .requests(let status): status.rawValue
            }
        }

        var title: String {
            switch self {
            case .all: "All Members"
            case .requests(let status): status.title
            }
        }
    }

    private enum MemberAction {
        case kick
        case ban
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs
            switch tab {
            case .all: allMembers
            case .requests(let status): requests(status)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: Spacing.tight) {
            ForEach(visibleTabs) { candidate in
                Button {
                    tab = candidate
                    if case .requests(let status) = candidate {
                        store.load(joinRequests: status)
                    }
                } label: {
                    Text(candidate.title)
                        .font(.system(.subheadline, weight: tab == candidate ? .semibold : .regular))
                        .foregroundStyle(tab == candidate ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
                        .padding(.horizontal, Spacing.snug)
                        .padding(.vertical, 6)
                        .background(
                            tab == candidate ? SettingsSurface.controlSelected : .clear,
                            in: .settingsRect(7)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == candidate ? [.isSelected, .isButton] : .isButton)
            }
            Spacer()
        }
        .padding(.bottom, Spacing.snug)
    }

    /// The applicant tabs appear only where there is an application to make.
    private var visibleTabs: [Tab] {
        guard store.joinForm.value?.isEnabled == true else { return [.all] }
        return [.all] + GuildJoinRequest.Status.allCases.map(Tab.requests)
    }

    // MARK: All members

    private var allMembers: some View {
        LoadableContent(
            store.members,
            isEmpty: { $0.rows.isEmpty },
            empty: { EmptyRow(message: "No members matched.", symbolName: "person.2") }
        ) { page in
            let shown = filtered(page.rows)
            SettingsGroup("Members — \(page.total)") {
                SettingsCard {
                    SearchRow(query: $query, placeholder: "Search by name")
                    CardDivider()
                    SettingsPickerRow(
                        title: "Sort by",
                        options: GuildMemberRow.Sort.allCases.map { .init($0, $0.title) },
                        selection: Binding(
                            get: { sort },
                            set: { next in
                                sort = next
                                store.reloadMembers(sort: next)
                            }
                        )
                    )
                    ForEach(Array(shown.enumerated()), id: \.element.id) { _, member in
                        CardDivider()
                        row(member)
                    }
                }
                if page.rows.count < page.total {
                    SettingsFootnote(
                        "Showing the first \(page.rows.count) of \(page.total). "
                            + "Narrow the search to find somebody further down."
                    )
                }
            }
        }
    }

    private func filtered(_ rows: [GuildMemberRow]) -> [GuildMemberRow] {
        guard !query.isEmpty else { return rows }
        let needle = query.lowercased()
        return rows.filter {
            $0.name.lowercased().contains(needle) || $0.username.lowercased().contains(needle)
        }
    }

    private func row(_ member: GuildMemberRow) -> some View {
        ObjectRow(
            title: member.name,
            subtitle: subtitle(member),
            badge: member.name == member.username ? nil : member.username
        ) {
            RemoteImage(
                url: member.avatarHash.flatMap {
                    CDN.avatar(userID: member.id, hash: $0, side: 28)
                },
                side: 28
            ) {
                Circle().fill(SettingsSurface.controlTrough)
            }
            .frame(width: 28, height: 28)
            .clipShape(.circle)
        } trailing: {
            HStack(spacing: 2) {
                RowIconButton(symbolName: "person.badge.minus", label: "Remove \(member.name)") {
                    acting = member
                    action = .kick
                }
                RowIconButton(
                    symbolName: "hand.raised",
                    label: "Ban \(member.name)",
                    role: .destructive
                ) {
                    acting = member
                    action = .ban
                }
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { acting?.id == member.id },
                set: { if !$0 { acting = nil } }
            ),
            title: action == .kick
                ? "Remove \(member.name) from this server?"
                : "Ban \(member.name)?",
            message: action == .kick
                ? "They can rejoin with a new invite."
                : "They are removed and cannot come back.",
            confirmTitle: action == .kick ? "Remove" : "Ban"
        ) {
            Task {
                if action == .kick {
                    await store.kick(member.id)
                } else {
                    await store.ban(member.id)
                }
            }
        }
    }

    private func subtitle(_ member: GuildMemberRow) -> String {
        var parts: [String] = []
        if let joined = member.joinedAt {
            parts.append("Joined \(joined.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append(member.joinSource.title)
        if let inviter = member.joinSource.inviterID, let user = model.users[inviter] {
            parts.append("by \(user.preferredName)")
        }
        if member.isPending { parts.append("has not agreed to the rules") }
        if member.isTimedOut() { parts.append("timed out") }
        return parts.joined(separator: " · ")
    }

    // MARK: Applicants

    private func requests(_ status: GuildJoinRequest.Status) -> some View {
        LoadableContent(
            store.joinRequests[status] ?? .idle,
            isEmpty: \.isEmpty,
            empty: {
                EmptyRow(
                    message: status == .submitted
                        ? "Nobody is waiting."
                        : "Nothing here yet.",
                    symbolName: "envelope"
                )
            }
        ) { requests in
            SettingsGroup("\(status.title) — \(requests.count)") {
                ForEach(requests) { request in
                    SettingsCard {
                        ObjectRow(
                            title: request.displayName ?? request.username,
                            subtitle: request.createdAt.map {
                                "Applied \($0.formatted(.relative(presentation: .named)))"
                            },
                            badge: request.username
                        ) {
                            RemoteImage(
                                url: request.avatarHash.flatMap {
                                    CDN.avatar(userID: request.userID, hash: $0, side: 28)
                                },
                                side: 28
                            ) {
                                Circle().fill(SettingsSurface.controlTrough)
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(.circle)
                        } trailing: {
                            // Only a pending application can be judged. An
                            // approved one has already been, and a rejected one
                            // is refused by the route.
                            if status == .submitted {
                                HStack(spacing: Spacing.tight) {
                                    Button("Approve") {
                                        Task { await store.resolve(request.id, approve: true) }
                                    }
                                    .buttonStyle(.glassProminent)
                                    .controlSize(.small)
                                    Button("Reject") {
                                        Task { await store.resolve(request.id, approve: false) }
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                                }
                            }
                        }

                        ForEach(request.answers) { answer in
                            CardDivider()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(answer.question)
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundStyle(Ink.tertiary)
                                Text(answer.response)
                                    .font(SettingsType.rowLabel)
                                    .foregroundStyle(Ink.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SettingsMetrics.cardContentInset)
                            .padding(.vertical, Spacing.base)
                        }

                        if let reason = request.rejectionReason {
                            CardDivider()
                            Text("Rejected: \(reason)")
                                .font(SettingsType.rowSubtitle)
                                .foregroundStyle(Palette.destructive)
                                .padding(.horizontal, SettingsMetrics.cardContentInset)
                                .padding(.vertical, Spacing.base)
                        }
                    }
                    .padding(.bottom, Spacing.base)
                }
            }
        }
    }
}
