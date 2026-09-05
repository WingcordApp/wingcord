import SwiftUI
import WingcordCore

/// Somebody's full profile: a portrait identity panel, and a tabbed column
/// beside it.
///
/// **This replaces the single wide "stage", and the reason is a constraint
/// rather than a preference.** Profile frames and profile effects are
/// aspect-locked artwork authored for a card of roughly 340 × 430. Measured on
/// three live accounts, stretched to a 1,400-point sheet: a garland's lower arc
/// crossed the middle of the content, a cat draped its body over the whole
/// surface, and an effect flooded the header flat lavender. There is no way to
/// place a portrait composition on a landscape surface — so the surface has to
/// contain a portrait region, and that region is `ProfileIdentityPanel`.
///
/// The stage failed twice more, and both are fixed here rather than argued with:
///
///  - **Blank profiles.** An account with no banner, no bio, no board and no
///    connections left three small slabs in a corner and seven hundred points of
///    void. This sheet **sizes to its content** and clamps, so a short profile
///    is a short sheet.
///  - **Unbalanced packing.** A masonry's wide spans level every column they
///    cross. The masonry is still right *inside* a content column — it is what
///    packs the board — and it is no longer being asked to lay out a whole
///    profile.
struct ProfileSheet: View {
    var profile: ProfilePresentation
    var board: BoardPresentation?
    var activity: ProfileActivityPresentation
    /// The most room the window can spare. The sheet takes the width and as
    /// much of the height as its content actually needs.
    var maximumSize: CGSize
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var inspectedEmoji: EmojiRef?
    @State private var selectedTab: ProfileTab = .board

    /// Never shorter than this, whatever the content says. Below it the panel's
    /// own banner and avatar stop having room to be a portrait at all.
    private static let minimumHeight: CGFloat = 420

    private var ground: ProfileGround {
        ProfileGround(themeColorValues: profile.themeColorValues, isDerived: profile.isThemeDerived)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ProfileIdentityPanel(
                profile: profile,
                ground: ground,
                openEmoji: { inspectedEmoji = $0 },
                openLink: { model.openLink($0) }
            )
            .frame(maxHeight: maximumSize.height)

            contentColumn
                .frame(maxHeight: maximumSize.height)
        }
        .frame(width: maximumSize.width)
        .frame(minHeight: Self.minimumHeight)
        // **The whole of "sizes to its content".** A nil height proposal is what
        // makes each column's `ScrollView` report the height of what is *in* it
        // rather than filling whatever it was offered; the `maxHeight` on each
        // column is what stops a long profile from growing past the window. No
        // `GeometryReader`, no measurement written into `@State`, and therefore
        // no number that can outlive the thing it measured — `INVARIANTS.md` §2.
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
        }
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        // **After the shadow, and scoped to the panel.** Applied before it, the
        // overhanging artwork would be shadowed too — a drop shadow under a rose
        // hanging in free space, cast by nothing. Scoped to the panel because
        // that is the box the artwork was authored for; given the sheet's width
        // it is the stage's bug again.
        .profileFrame(profile.frame, over: ProfileIdentityPanel.width)
        .presentationBackground(.clear)
        .presentsExpressionInfo(for: $inspectedEmoji)
    }

    // MARK: The tabbed column

    /// Which tabs have anything behind them.
    private var tabs: [ProfileTab] {
        ProfileTab.available(profile: profile, board: board, activity: activity)
    }

    /// The tab actually being drawn.
    ///
    /// Derived rather than stored, because the set it has to belong to arrives
    /// over the network: a board landing a beat after the sheet opened must not
    /// leave the selection pointing at a tab that did not exist when it was
    /// made, and a stored selection corrected in an `onChange` is a second write
    /// that invalidates the whole sheet.
    private var currentTab: ProfileTab {
        tabs.contains(selectedTab) ? selectedTab : (tabs.first ?? .mutuals)
    }

    /// The handoff's own gutter for this column: 28 at its 1,280-point sheet.
    private static let gutter: CGFloat = 22

    private var contentColumn: some View {
        ScrollView {
            pane
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.gutter)
                .padding(.bottom, Spacing.group)
        }
        .scrollIndicators(.never)
        .softScrollEdgesVertical()
        // The picker floats over the content it switches, which is the app's
        // documented `floatingTopBar` exception to "never stack glass on glass"
        // — and it is what registers the bar the scroll edge effect keys off.
        .floatingTopBar { topBar }
        .frame(maxWidth: .infinity)
        // **The same ground as the panel, from the same person, so the sheet is
        // one surface.** This column used to be lit by `AmbientArtwork` — the
        // banner blurred at a 64-point rung and spread underneath — which is a
        // picture, not a decision: a member with a dark red theme and a pale
        // banner got a dark red rail beside a dusty pink board, and the colour
        // on two thirds of their profile was one they never chose.
        //
        // It is the rule `ProfileGround`'s own doc comment opens with, applied
        // to the other half of the sheet: **artwork does not tint the body.**
        // Discord derives colours from a picture in exactly one case — full
        // Nitro, no `theme_colors` set — and that case already arrives here as
        // `ProfileGround.derived`, fitted against Discord's own card. Anything
        // that reaches past it for the picture again is answering a question
        // that has already been answered.
        .modifier(ProfileGroundFill(ground: ground, corner: 0))
    }

    private var topBar: some View {
        HStack(spacing: Spacing.snug) {
            // **No picker for one tab.** A segmented control with a single
            // segment is a label that looks pressable.
            if tabs.count > 1 {
                SegmentedPicker(
                    options: tabs.map { SegmentedPicker.Option($0, $0.title) },
                    selection: Binding(
                        get: { currentTab },
                        set: { selectedTab = $0 }
                    )
                )
            }
            Spacer(minLength: Spacing.base)
            if !profile.mutualServers.isEmpty {
                mutualCount
            }
            closeButton
        }
        .padding(.leading, Self.gutter)
        .padding(.trailing, Spacing.snug)
        .padding(.top, 21)
        .padding(.bottom, 16)
    }

    private var mutualCount: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ground.accent ?? Palette.presenceOnline)
                .frame(width: 6, height: 6)
            Text(
                profile.mutualServers.count == 1
                    ? "1 mutual server"
                    : "\(profile.mutualServers.count) mutual servers"
            )
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(InkColor.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 27)
        .chromeOverMedia(tinted: Palette.flyoutTint)
        .accessibilityElement(children: .combine)
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        // See `View.cancelAction(unless:)`: a game profile opened from this
        // sheet's own board sits on top of it and owns Escape while it is there.
        .cancelAction(unless: model.gameProfileRequest != nil)
        .accessibilityLabel(Text("Close"))
    }

    // MARK: The panes

    @ViewBuilder
    private var pane: some View {
        switch currentTab {
        case .board: boardPane
        case .activity: activityPane
        case .mutuals: mutualsPane
        }
    }

    /// The board, packed.
    ///
    /// **`MasonryLayout` inside a content column, which is where it was always
    /// right.** It sizes each tile to its own content, so a two-chip detail card
    /// does not inherit the height of a nine-cover wall. The column count falls
    /// out of the width, which is the sheet's minus the panel — two at the
    /// sheet's ceiling, one in a narrow window.
    @ViewBuilder
    private var boardPane: some View {
        if let board {
            MasonryLayout(columns: boardColumns, spacing: 14) {
                ForEach(board.tiles) { tile in
                    BoardSlab(tile: tile, ground: ground, userID: profile.userID)
                        .masonrySpan(tile.preferredSpan)
                }
            }
            .padding(.top, Spacing.base)
        }
    }

    /// A slab is comfortable at 320; the column decides how many fit.
    private var boardColumns: Int {
        let usable = maximumSize.width - ProfileIdentityPanel.width - Spacing.group * 2
        return min(max(Int(usable / 320), 1), 2)
    }

    @ViewBuilder
    private var activityPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let current = profile.activity {
                ProfileSlab(ground: ground) {
                    CurrentActivityCard(
                        activity: current,
                        buttonURLs: profile.activityButtonURLs,
                        ground: ground,
                        openGame: gameOpener(for: current)
                    )
                }
            }
            if !activity.recent.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text("Recent Activity")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                    ProfileSlab(ground: ground) {
                        VStack(spacing: 2) {
                            ForEach(activity.recent) { entry in
                                RecentActivityRow(
                                    entry: entry,
                                    ground: ground,
                                    coverURL: activity.covers[entry.id],
                                    openGame: entry.subject.applicationID.map { id in
                                        { model.openGameProfile(id) }
                                    }
                                )
                            }
                        }
                        // The slab pads its content and these rows carry their
                        // own hover plate, so the padding is taken back here —
                        // a highlight inset from the card it is inside reads as
                        // a second card.
                        .padding(-Spacing.snug)
                    }
                }
            } else if activity.isLoading {
                loadingRow
            }
            if profile.activity == nil, activity.recent.isEmpty, !activity.isLoading {
                emptyPane("\(profile.displayName) hasn't shared any activity.")
            }
        }
        .padding(.top, Spacing.base)
    }

    /// What a click on the current activity's name and artwork does.
    ///
    /// **Only for a game.** A `playing` activity with an application id has a
    /// game profile behind it; a custom status, a Spotify session and an
    /// activity nobody has a page for do not, and a title that looks pressable
    /// and opens nothing is what `INVARIANTS.md` §5.5 forbids.
    private func gameOpener(for activity: Activity) -> (() -> Void)? {
        guard activity.kind == .playing, let id = activity.applicationID else { return nil }
        return { model.openGameProfile(id) }
    }

    @ViewBuilder
    private var mutualsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !profile.mutualServers.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text(mutualServersTitle)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                    ProfileSlab(ground: ground) {
                        MutualServersList(servers: profile.mutualServers)
                    }
                }
            }
            if !profile.mutualFriends.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text(mutualFriendsTitle)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                    ProfileSlab(ground: ground) {
                        MutualFriendsList(friends: profile.mutualFriends)
                    }
                }
            }
            if profile.mutualServers.isEmpty, profile.mutualFriends.isEmpty {
                emptyPane(
                    profile.isLoading
                        ? "Loading…"
                        : "No servers or friends in common."
                )
            }
        }
        .padding(.top, Spacing.base)
    }

    /// What a tab says when the honest answer is nothing.
    ///
    /// **One line, centred, and no illustration.** These tabs are always
    /// offered — see `ProfileTab.available` — so "nothing" is a state the reader
    /// reaches on purpose rather than an error, and it is answered the way the
    /// rest of the app answers an empty list. The minimum height is what stops a
    /// sentence floating at the top of a column the identity panel has already
    /// made six hundred points tall; the sheet still sizes to its content, so a
    /// short profile is still a short sheet.
    private func emptyPane(_ message: String) -> some View {
        Text(message)
            .font(.system(.subheadline))
            .foregroundStyle(InkColor.tertiary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: .infinity, minHeight: 200)
            .padding(.vertical, Spacing.group)
    }

    private var loadingRow: some View {
        HStack(spacing: Spacing.base) {
            ProgressView().controlSize(.small)
            Text("Loading their activity…")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(InkColor.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.snug)
    }

    private var mutualServersTitle: String {
        profile.mutualServers.count == 1
            ? "1 Mutual Server"
            : "\(profile.mutualServers.count) Mutual Servers"
    }

    private var mutualFriendsTitle: String {
        profile.mutualFriends.count == 1
            ? "1 Mutual Friend"
            : "\(profile.mutualFriends.count) Mutual Friends"
    }
}

/// The three things a profile's content column can be showing.
enum ProfileTab: Hashable, CaseIterable, Sendable {
    case board
    case activity
    case mutuals

    var title: String {
        switch self {
        case .board: "Board"
        case .activity: "Activity"
        case .mutuals: "Mutuals"
        }
    }

    /// The tabs this profile offers, in the order they are drawn.
    ///
    /// **Activity and Mutuals are always offered; the Board is not.** The
    /// distinction is what the tab's absence would *mean*. Everybody has an
    /// answer to "what are they doing" and "what do we share" — often "nothing",
    /// which is a real answer and the column says so in a line — so hiding those
    /// tabs makes the picker's shape change from person to person and takes away
    /// a place the reader knows to look. A board is a thing somebody *made*, and
    /// a Board tab on an account that has never made one is a promise of a
    /// surface that does not exist.
    ///
    /// This reverses the rule that used to be here, which hid all three. Discord
    /// keeps its own Activity and Mutuals tabs on an empty profile and labels
    /// them with the count, and it is right: see `docs/PROFILE-DESIGN-SPEC.md`.
    ///
    /// A function on the tab rather than a computed property on the sheet, so
    /// the gating is reachable from a test — the decision it makes is invisible
    /// in a rendered view and would otherwise only be checkable by opening
    /// somebody's profile and counting.
    static func available(
        profile: ProfilePresentation,
        board: BoardPresentation?,
        activity: ProfileActivityPresentation
    ) -> [ProfileTab] {
        var tabs: [ProfileTab] = []
        if board?.tiles.isEmpty == false { tabs.append(.board) }
        tabs.append(.activity)
        tabs.append(.mutuals)
        return tabs
    }
}

/// What the Activity tab draws, resolved once.
///
/// Separate from `ProfilePresentation` rather than folded into it, because the
/// card beside a message draws none of it: an array of twenty inventory entries
/// on the shared value would invalidate every mini profile in the window
/// whenever one of them landed.
struct ProfileActivityPresentation: Equatable, Sendable {
    var recent: [RecentActivity] = []
    /// Box art for the game rows, by entry id. Joined here rather than in the
    /// row's body, which would redo the lookup on every hover.
    var covers: [String: URL] = [:]
    var isLoading: Bool = false

    var isEmpty: Bool { recent.isEmpty }
}

extension BoardTile {
    /// How much of the grid this tile asks for.
    ///
    /// **An application widget takes the full width and a cover grid takes what
    /// it can get.** The first carries hero artwork and six stats across three
    /// columns; the second is a wall of box art that only reads as a collection
    /// when it is wide. A detailed list sits in the middle: two columns is
    /// enough for a cover, a name and a row of badges without wrapping.
    var preferredSpan: Int {
        switch content {
        case .application: 3
        case .grid: 2
        case .detailed: 2
        }
    }
}
