import SwiftUI
import WingcordCore

/// The people the reader is connected to, on the home (REDESIGN.md R12):
/// Discord's Friends page — Online, All, Pending and Blocked — with Add Friend
/// beside the tabs and a filter over the list.
struct FriendsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var tab = FriendsTab.online
    @State private var query = ""
    /// The page's width, which decides whether Active Now has room beside it.
    @State private var width: CGFloat = 0

    /// Wide enough for the list and the column side by side, as Discord lays
    /// them; under it the list has the page to itself.
    private static let activeNowThreshold: CGFloat = 900

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            friends
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if width >= Self.activeNowThreshold {
                Divider()
                    .padding(.vertical, Spacing.base)
                ActiveNowColumn(
                    cards: model.activeNowCards(),
                    open: { model.messagePerson($0) },
                    join: { model.joinFriendActivity($0) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(motion.standard, value: width >= Self.activeNowThreshold)
    }

    private var friends: some View {
        let rows = rows(for: tab)
        return VStack(alignment: .leading, spacing: Spacing.base * 1.5) {
            HStack(spacing: Spacing.base) {
                // The system's capsule tab strip, as the inbox's — see
                // `SegmentedPicker`.
                SegmentedPicker(
                    options: FriendsTab.allCases.map { .init($0, title(of: $0)) },
                    selection: $tab
                )
                Spacer(minLength: 0)
                Button {
                    AddFriendRequest.shared.isShown = true
                } label: {
                    Label("Add Friend", systemImage: "person.badge.plus")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        // **Exactly the strip's height.** The prominent glass
                        // style sizes itself from the control size, and its
                        // extra-large is a few points taller than the
                        // segmented strip beside it — three pills of two
                        // heights read as a mistake.
                        .frame(height: SegmentedPicker<FriendsTab>.stripHeight)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                // The prominent glass itself: the material, tinted with the
                // accent and answering the pointer, in the capsule.
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                .help("Add Friend")
            }
            SearchField(text: $query)
            // Discord's Friend Anniversaries, above the list on Online and
            // All: friends whose friendship turns a year older this week.
            let anniversaries = (tab == .online || tab == .all) && query.isEmpty
                ? model.friendAnniversaries() : []
            if !anniversaries.isEmpty {
                Text("FRIEND ANNIVERSARIES — \(anniversaries.count)")
                    .font(Typeface.categoryHeader)
                    .foregroundStyle(Ink.tertiary)
                VStack(spacing: 0) {
                    ForEach(anniversaries) { anniversary in
                        FriendAnniversaryRow(anniversary: anniversary)
                    }
                }
            }
            Text("\(tab.heading.uppercased()) — \(rows.count)")
                .font(Typeface.categoryHeader)
                .foregroundStyle(Ink.tertiary)
            if rows.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            FriendRow(row: row)
                            if row.id != rows.last?.id { Divider().opacity(0.5) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, Spacing.margin * 1.5)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(motion.standard, value: tab)
    }

    private func title(of tab: FriendsTab) -> String {
        guard tab == .pending else { return tab.title }
        let incoming = FriendRequest.incomingCount(of: model.relationships)
        return incoming > 0 ? "Pending (\(incoming))" : tab.title
    }

    private var empty: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: tab.emptySymbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Ink.tertiary)
            Text(tab.emptyText)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.group * 2)
    }

    /// One tab's people, by name, filtered by the search field.
    private func rows(for tab: FriendsTab) -> [FriendRow.Model] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows: [FriendRow.Model] = []
        for (userID, relationship) in model.relationships {
            let status = model.presenceStatus(of: userID)
            let fits: Bool = switch tab {
            case .online: relationship == .friend && status != .offline && status != .invisible && status != .unknown
            case .all: relationship == .friend
            case .pending: relationship == .incomingRequest || relationship == .outgoingRequest
            case .blocked: relationship == .blocked
            }
            guard fits else { continue }
            let user = model.users[userID]
            let name = model.friendNicknames[userID] ?? user?.preferredName ?? "Unknown"
            if !needle.isEmpty,
               !name.lowercased().contains(needle),
               !(user?.handle.lowercased().contains(needle) ?? false) {
                continue
            }
            let presence = model.presences[userID]
            let line: String = switch relationship {
            case .incomingRequest: "Incoming Friend Request"
            case .outgoingRequest: "Outgoing Friend Request"
            case .blocked: "Blocked"
            default:
                presence?.customStatus?.state
                    ?? presence?.primaryActivity.map { "Playing \($0.name)" }
                    ?? status.label
            }
            rows.append(FriendRow.Model(
                id: userID,
                name: name,
                handle: user?.handle ?? "",
                avatarURL: user.flatMap { model.avatarURL(for: $0, side: 36) },
                monogram: user?.monogram ?? "?",
                status: status,
                client: presence?.client ?? .desktop,
                line: line,
                relationship: relationship
            ))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum FriendsTab: CaseIterable, Identifiable, Hashable {
    case online
    case all
    case pending
    case blocked

    var id: Self { self }

    var title: String {
        switch self {
        case .online: "Online"
        case .all: "All"
        case .pending: "Pending"
        case .blocked: "Blocked"
        }
    }

    var heading: String {
        switch self {
        case .online: "Online"
        case .all: "All friends"
        case .pending: "Pending"
        case .blocked: "Blocked"
        }
    }

    var emptySymbol: String {
        switch self {
        case .online, .all: "person.2"
        case .pending: "envelope.open"
        case .blocked: "hand.raised"
        }
    }

    var emptyText: String {
        switch self {
        case .online: "No friends are online right now."
        case .all: "No friends yet. Add one with their username."
        case .pending: "There are no pending friend requests."
        case .blocked: "You haven't blocked anyone."
        }
    }
}

/// One person: their face and status, their name, what they are doing — and
/// what can be done about them from here.
private struct FriendRow: View {
    struct Model: Identifiable, Hashable {
        var id: UserID
        var name: String
        var handle: String
        var avatarURL: URL?
        var monogram: String
        var status: PresenceStatus
        var client: PresenceClient = .desktop
        var line: String
        var relationship: Relationship
    }

    var row: Model

    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: row.avatarURL, monogram: row.monogram, side: 36)
                .overlay(alignment: .bottomTrailing) {
                    if row.relationship == .friend {
                        PresenceDot(status: row.status, side: 12, client: row.client)
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    if isHovered, !row.handle.isEmpty {
                        Text(row.handle)
                            .font(.system(.body))
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                .lineLimit(1)
                Text(row.line)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                if row.relationship == .incomingRequest {
                    FriendRequestNoteLine(userID: row.id)
                }
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.vertical, Spacing.tight + 2)
        .padding(.horizontal, Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isHovered ? Palette.hoverFill : .clear)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard row.relationship == .friend else { return }
            model.messagePerson(row.id)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch row.relationship {
        case .friend:
            circle("Message", "bubble.left.fill") { model.messagePerson(row.id) }
            Menu {
                Button("Start a Call") { model.callPerson(row.id) }
                Divider()
                Button("Remove Friend", role: .destructive) { model.toggleFriend(with: row.id) }
                Button("Block", role: .destructive) { model.askToBlock(row.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(FriendsInk.control))
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        case .incomingRequest:
            circle("Accept", "checkmark") { model.toggleFriend(with: row.id) }
            circle("Ignore", "xmark") { model.declineFriendRequest(row.id) }
        case .outgoingRequest:
            circle("Cancel", "xmark") { model.declineFriendRequest(row.id) }
        case .blocked:
            circle("Unblock", "person.fill.checkmark") { model.setBlocked(false, userID: row.id) }
        case .none:
            EmptyView()
        }
    }

    private func circle(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(FriendsInk.control))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

private nonisolated enum FriendsInk {
    static let control = Color.relative(dark: 0.10, light: 0.07)
}

private extension PresenceStatus {
    var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .doNotDisturb: "Do Not Disturb"
        case .invisible, .offline, .unknown: "Offline"
        }
    }
}

// MARK: - Active Now

/// The Friends page's right-hand column (#18): every friend doing something,
/// as Discord's own Friends page has it.
///
/// **Cards on a standard material, not Liquid Glass**: this is the page's
/// content, and the HIG keeps glass for the controls floating over it
/// ("Don't use Liquid Glass in the content layer").
struct ActiveNowColumn: View {
    var cards: [ActiveNowCard]
    /// A card clicked: the conversation with them.
    var open: (UserID) -> Void
    /// Join Activity on a card that offers it.
    var join: (UserID) -> Void = { _ in }

    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Active Now")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(Ink.primary)
                .accessibilityAddTraits(.isHeader)
            if cards.isEmpty {
                quiet
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.base) {
                        ForEach(cards) { card in
                            ActiveNowCardView(card: card, open: { open(card.id) }, join: { join(card.id) })
                        }
                    }
                    .padding(.bottom, Spacing.margin)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.tight)
        .frame(width: 330)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(motion.standard, value: cards.map(\.id))
    }

    /// Discord's own words for an empty column.
    private var quiet: some View {
        VStack(alignment: .center, spacing: Spacing.base) {
            Text("It\u{2019}s quiet for now\u{2026}")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
            Text("When a friend starts an activity, like playing a game or hanging out in voice, it\u{2019}ll show up here.")
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.margin)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.glass, style: .continuous))
    }
}

private struct ActiveNowCardView: View {
    var card: ActiveNowCard
    var open: () -> Void
    var join: () -> Void = {}

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(spacing: Spacing.snug) {
                    AvatarView(url: card.avatarURL, monogram: card.monogram, side: 36)
                        .overlay(alignment: .bottomTrailing) {
                            PresenceDot(status: card.status, side: 12, client: card.client)
                                .offset(x: 2, y: 2)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Text(card.headline)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(Ink.primary.opacity(0.85))
                        if !card.detail.isEmpty {
                            Text(card.detail)
                                .font(.system(.caption))
                                .foregroundStyle(Ink.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    art
                }
                if card.roomCount > 1 {
                    HStack(spacing: Spacing.tight) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Ink.secondary)
                        HStack(spacing: -5) {
                            ForEach(Array(card.roomFaces.enumerated()), id: \.offset) { _, face in
                                AvatarView(url: face.url, monogram: face.monogram, side: 18)
                                    .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                            }
                        }
                        Text("\(card.roomCount) in voice")
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                    }
                    .padding(.leading, 48)
                }
            }
            .padding(Spacing.snug)
            // Room for Join Activity, which floats over the card's foot.
            .padding(.bottom, card.canJoinActivity ? 34 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.glass, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .strokeBorder(Ink.primary.opacity(isHovered ? 0.18 : 0.06), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.glass, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            // Outside the card's own button: a button inside another's label
            // never gets the click.
            if card.canJoinActivity {
                Button("Join Activity", action: join)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Palette.accent)
                    .padding(Spacing.snug)
            }
        }
        .scaleEffect(isHovered ? 1.01 : 1)
        .onHover { hovering in
            guard isHovered != hovering else { return }
            isHovered = hovering
        }
        .animation(motion.hover, value: isHovered)
        .help("Message \(card.name)")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var art: some View {
        Group {
            if let url = card.artURL {
                RemoteImage(url: url, side: 40) {
                    Image(systemName: card.artSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 40, height: 40)
                        .background(Palette.surfaceRaised)
                }
            } else {
                Image(systemName: card.artSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 40, height: 40)
                    .background(Palette.surfaceRaised)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(.rect(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}
