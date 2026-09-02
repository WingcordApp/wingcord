import SwiftUI
import WingcordCore

// MARK: - Connected Apps
//
// Two lists — `GET /users/@me/connections` and `GET /oauth2/tokens` — behind
// one segmented control, the same shape General, Appearance and Voice & Video
// already switch sub-content with. Discord's own settings gives these two
// separate rows in its sidebar; this window's sidebar is a flat, single-level
// list everywhere else in the app, and a second exception here would be a
// pane deciding its own navigation instead of using the one this window has.
//
// Both lists are asked for together when the pane appears — Discord's own
// client fetches both regardless of which tab is showing, confirmed against a
// capture of the real settings window — so switching tabs never shows a
// flicker of loading state on the second visit.

struct ConnectedAppsPane: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .connections

    private enum Mode: Hashable, Sendable {
        case connections
        case authorizedApps
    }

    var body: some View {
        @Bindable var model = model
        Group {
            SettingsCard {
                CardHeaderRow(title: "Show")
                SettingsSegmentedControl(
                    selection: $mode,
                    options: [
                        .init(.connections, "Connections", symbolName: "link"),
                        .init(.authorizedApps, "Authorized Apps", symbolName: "checkmark.shield"),
                    ]
                )
            }

            switch mode {
            case .connections: ConnectionsSection()
            case .authorizedApps: AuthorizedAppsSection()
            }
        }
        // Read here, not inside the presentation closure, so the sheet is
        // handed a value rather than an optional it has to unwrap — the same
        // rule `GuildSurfacePresenter` follows for its own two sheets.
        .sheet(item: $model.domainConnectionSheet) { sheet in
            ConnectDomainSheet(sheet: sheet)
        }
    }
}

// MARK: - Connections

private struct ConnectionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup("Add a new connection") {
            SettingsCard { AddConnectionGrid() }
        }

        SettingsGroup(heading) {
            if let connections = model.connections {
                if connections.isEmpty {
                    SettingsCard {
                        SettingsValueRow(title: "Connections", value: "None")
                    }
                } else {
                    VStack(spacing: Spacing.base) {
                        ForEach(connections) { ConnectionCard(connection: $0) }
                    }
                }
            } else {
                SettingsCard {
                    SettingsValueRow(title: "Connections", value: "—")
                }
            }
        }
        .task {
            model.sessionController.loadConnections()
            model.sessionController.loadAuthorizedApps()
        }
    }

    private var heading: String {
        guard let count = model.connections?.count else { return "Connections" }
        return "\(count) connection\(count == 1 ? "" : "s")"
    }
}

/// One linked account: its platform tile, its two toggles, and the way out.
private struct ConnectionCard: View {
    var connection: AccountConnection
    @Environment(AppModel.self) private var model

    private var isMutating: Bool {
        model.connectionMutationsInFlight.contains(connection.id)
    }

    /// The same lookup `ConnectionChip` uses on a profile card: the brand's own
    /// spelling where this app has a mark for it, the raw key capitalized where
    /// it does not.
    private var platformName: String {
        BrandMark.mark(for: connection.type)?.name ?? connection.type.capitalized
    }

    var body: some View {
        SettingsCard {
            HStack(spacing: SettingsMetrics.navigationIconGap) {
                ConnectionMark(service: connection.type, side: SettingsMetrics.navigationIconSide)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.name)
                        .font(SettingsType.rowTitle)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(platformName)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: Spacing.base)
                Button {
                    model.sessionController.removeConnection(connection)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(isMutating)
                .accessibilityLabel("Remove \(connection.name)")
            }
            .padding(.leading, SettingsMetrics.navigationIconLeading)
            .padding(.trailing, SettingsMetrics.controlTrailing)
            .frame(minHeight: SettingsMetrics.navigationRowHeight)

            CardDivider()

            SettingsToggle(
                title: "Display on profile",
                isOn: Binding(
                    get: { connection.isVisibleOnProfile },
                    set: { model.sessionController.setConnectionVisible($0, connection) }
                )
            )
            .disabled(isMutating)

            CardDivider()

            SettingsToggle(
                title: "Display \(platformName) as your status",
                isOn: Binding(
                    get: { connection.showsActivity },
                    set: { model.sessionController.setConnectionShowsActivity($0, connection) }
                )
            )
            .disabled(isMutating)
        }
    }
}

/// The grid of platforms a new connection can be started for.
///
/// Every tile opens the system browser to Discord's own OAuth2 page for that
/// platform and returns nothing this app can catch — the toolbar's Refresh is
/// how a reader who has finished in the browser sees the result.
private struct AddConnectionGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = [
        GridItem(.adaptive(minimum: SettingsMetrics.navigationIconSide, maximum: SettingsMetrics.navigationIconSide), spacing: Spacing.base)
    ]

    /// Sorted by the same name the tiles are named for — `BrandMark`'s own
    /// spelling, not the raw wire key, or "eBay" and "PlayStation" would fall
    /// wherever their lowercase-first-letter key happened to land. `domain`
    /// sorts in with everything else — it is a platform to add, it just does
    /// not open a browser to add it.
    private var sortedTypes: [String] {
        (ConnectionPlatform.addable + [ConnectionPlatform.domain]).sorted {
            (BrandMark.mark(for: $0)?.name ?? $0) < (BrandMark.mark(for: $1)?.name ?? $1)
        }
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.base) {
            ForEach(sortedTypes, id: \.self) { type in
                let name = type == ConnectionPlatform.domain ? "Domain" : (BrandMark.mark(for: type)?.name ?? type.capitalized)
                Button(action: { tap(type) }) {
                    ConnectionMark(service: type, side: SettingsMetrics.navigationIconSide)
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel("Add \(name)")
            }
        }
        .padding(SettingsMetrics.cardContentInset)
    }

    private func tap(_ type: String) {
        if type == ConnectionPlatform.domain {
            model.sessionController.beginDomainConnection()
        } else {
            model.sessionController.beginLinkingConnection(type: type)
        }
    }
}

// MARK: - Authorized Apps

private struct AuthorizedAppsSection: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        // Only once there is enough to search. A field over eight rows is
        // furniture; a real account in this capture had ninety-five.
        if let count = model.authorizedApps?.count, count > 8 {
            SettingsCard {
                ConnectedAppsSearchField(query: $query)
            }
        }

        SettingsGroup(heading) {
            if let apps = model.authorizedApps {
                let visible = filtered(apps)
                if apps.isEmpty {
                    SettingsCard {
                        SettingsValueRow(title: "Authorized Apps", value: "None")
                    }
                } else if visible.isEmpty {
                    SettingsCard {
                        SettingsValueRow(title: "Authorized Apps", value: "No matches")
                    }
                } else {
                    VStack(spacing: Spacing.base) {
                        ForEach(visible) { AuthorizedAppCard(app: $0) }
                    }
                }
            } else {
                SettingsCard {
                    SettingsValueRow(title: "Authorized Apps", value: "—")
                }
            }
        }
    }

    private var heading: String {
        guard let count = model.authorizedApps?.count else { return "Authorized Apps" }
        return "\(count) authorized app\(count == 1 ? "" : "s")"
    }

    private func filtered(_ apps: [AuthorizedApp]) -> [AuthorizedApp] {
        guard !query.isEmpty else { return apps }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(needle) }
    }
}

/// One authorized app, collapsed to a name and a date until asked for more.
///
/// **Collapsed by default, and not a cosmetic choice.** A permission list is
/// most of a dozen rows, and this pane's own capture came from an account
/// with ninety-five authorized apps — building every card's full permission
/// list at once is view-tree weight nobody asked for until they open one.
private struct AuthorizedAppCard: View {
    var app: AuthorizedApp
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isExpanded = false

    private var isMutating: Bool {
        model.authorizedAppRevocationsInFlight.contains(app.id)
    }

    private var iconURL: URL? {
        app.iconHash.flatMap { CDN.applicationIcon(id: app.applicationID, hash: $0) }
    }

    var body: some View {
        SettingsCard {
            Button {
                withAnimation(motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: SettingsMetrics.navigationIconGap) {
                    RemoteImage(url: iconURL, side: SettingsMetrics.navigationIconSide) {
                        Text(AppModel.monogram(of: app.name))
                            .font(.system(size: SettingsMetrics.navigationIconSide * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(
                                width: SettingsMetrics.navigationIconSide,
                                height: SettingsMetrics.navigationIconSide
                            )
                            .background(Color(hex: 0x5E5CE6).gradient)
                    }
                    .frame(width: SettingsMetrics.navigationIconSide, height: SettingsMetrics.navigationIconSide)
                    .clipShape(.settingsRect(SettingsMetrics.navigationIconRadius))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(SettingsType.rowTitle)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Text("Authorized \(app.authorizedAt.formatted(date: .numeric, time: .omitted))")
                            .font(SettingsType.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: Spacing.base)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.leading, SettingsMetrics.navigationIconLeading)
                .padding(.trailing, SettingsMetrics.navigationChevronTrailing)
                .frame(minHeight: SettingsMetrics.navigationRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                CardDivider()
                if !app.description.isEmpty {
                    Text(app.description)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SettingsMetrics.cardContentInset)
                        .padding(.vertical, Spacing.base)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasPolicyLinks { CardDivider() }
                }
                if hasPolicyLinks { PolicyLinksRow(app: app) }

                CardDivider()
                CardHeaderRow(title: "Permissions")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(app.scopes, id: \.self) { scope in
                        ScopeRow(scope: scope)
                    }
                }
                .padding(.bottom, Spacing.snug)

                CardDivider()
                SettingsActionRow(
                    "Remove this app's access",
                    actionTitle: "Deauthorize",
                    role: .destructive
                ) {
                    model.sessionController.deauthorizeApp(app)
                }
                .disabled(isMutating)
            }
        }
    }

    private var hasPolicyLinks: Bool {
        app.termsOfServiceURL != nil || app.privacyPolicyURL != nil
    }
}

private struct ScopeRow: View {
    var scope: String

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x30D158))
            Text(OAuthScope.description(scope))
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .frame(minHeight: 28, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct PolicyLinksRow: View {
    var app: AuthorizedApp

    var body: some View {
        HStack(spacing: Spacing.base) {
            if let url = app.termsOfServiceURL {
                Link("Terms of Service", destination: url)
            }
            if let url = app.privacyPolicyURL {
                Link("Privacy Policy", destination: url)
            }
            Spacer(minLength: 0)
        }
        .font(SettingsType.rowSubtitle)
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.snug)
    }
}

// MARK: - Search

/// The same visual recipe as the source list's own search field — a capsule,
/// a glyph and a clear button — kept local rather than shared: the sidebar's
/// version is wired to that list's keyboard focus and its own metrics, and
/// this one has neither.
private struct ConnectedAppsSearchField: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7.5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 12, height: 12)
            TextField("Search installed apps", text: $query)
                .textFieldStyle(.plain)
                .font(SettingsType.sidebarRow)
                .foregroundStyle(Ink.primary)
                .focused($isFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10.5)
        .frame(height: SettingsMetrics.searchFieldHeight)
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
    }
}
