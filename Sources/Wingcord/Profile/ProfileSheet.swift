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
    /// Non-nil while the reader is editing their own profile. The sheet is the
    /// preview *and* the surface — see `ProfileEditRail` — so there is no second
    /// view for edit mode, only a rail beside this one and fields in place of
    /// some of its labels.
    var editor: ProfileEditor?
    var beginEditing: () -> Void
    var endEditing: () -> Void
    /// Every profile the reader can edit — their own, then each server. Empty
    /// outside an edit, where there is nothing to switch.
    var scopes: [ProfileEditScope] = []
    var selectScope: (ProfileEditScope) -> Void = { _ in }
    var saveEdits: () -> Void
    var presentPicker: (ProfileEditPicker) -> Void
    var dismiss: () -> Void
    /// The tab to open on — Activity from an activity's peek, the board from a
    /// widget's. Nil is the board.
    var initialTab: ProfileTab? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var inspectedEmoji: EmojiRef?
    /// The tab the reader chose, once they have. **Only their choice is
    /// state**; where the sheet opened is an input, so it needs no write after
    /// the first frame to take effect.
    @State private var chosenTab: ProfileTab?

    /// Never shorter than this, whatever the content says. Below it the panel's
    /// own banner and avatar stop having room to be a portrait at all.
    private static let minimumHeight: CGFloat = 420

    /// **What every part of this sheet draws from.** While the editor is open
    /// it is the draft applied to the profile, so a picked avatar, a typed
    /// pronoun or a chosen nameplate is on screen before anything is saved —
    /// see `ProfileEditor.applied(to:)`.
    private var shown: ProfilePresentation {
        guard let editor else { return profile }
        return editor.applied(to: editor.base)
    }

    private var ground: ProfileGround {
        ProfileGround(themeColorValues: shown.themeColorValues)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let editor {
                ProfileEditRail(
                    editor: editor,
                    profile: shown,
                    scopes: scopes,
                    selectScope: selectScope,
                    collapse: endEditing,
                    present: presentPicker
                )
                .frame(maxHeight: maximumSize.height)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ProfileIdentityPanel(
                profile: shown,
                ground: ground,
                openEmoji: { inspectedEmoji = $0 },
                openLink: { model.openLink($0) },
                editor: editor,
                tagOptions: tagOptions,
                present: presentPicker
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
        // **Over the sheet's foot, not inside its layout.** A bar that took a
        // strip out of the stack would resize the profile the instant the first
        // character was typed — and the profile is the thing being looked at.
        .overlay(alignment: .bottom) {
            if let editor, editor.isDirty {
                ProfileEditBar(editor: editor, save: saveEdits)
                    .padding(Spacing.margin)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion.panel, value: editor?.isDirty)
        // **After the shadow, and scoped to the panel.** Applied before it, the
        // overhanging artwork would be shadowed too — a drop shadow under a rose
        // hanging in free space, cast by nothing. Scoped to the panel because
        // that is the box the artwork was authored for; given the sheet's width
        // it is the stage's bug again.
        .profileFrame(shown.frame, over: ProfileIdentityPanel.width)
        .presentationBackground(.clear)
        .presentsExpressionInfo(for: $inspectedEmoji)
    }

    // MARK: The tabbed column

    /// Which tabs have anything behind them.
    private var tabs: [ProfileTab] {
        ProfileTab.available(
            profile: profile,
            board: board,
            activity: activity,
            isEditing: editor != nil
        )
    }

    /// The tab actually being drawn.
    ///
    /// Derived rather than stored, because the set it has to belong to arrives
    /// over the network: a board landing a beat after the sheet opened must not
    /// leave the selection pointing at a tab that did not exist when it was
    /// made, and a stored selection corrected in an `onChange` is a second write
    /// that invalidates the whole sheet.
    private var currentTab: ProfileTab {
        let wanted = chosenTab ?? initialTab ?? .board
        return tabs.contains(wanted) ? wanted : (tabs.first ?? .mutuals)
    }

    /// The servers whose tag the reader could wear.
    ///
    /// **Just the one they are already wearing, and that is the honest list.**
    /// Discord's own menu shows every server that *has* a tag, and this client
    /// cannot build that list: `Guild` carries no tag, and nothing captured says
    /// which of the reader's servers have `GUILD_TAGS` — the field arrives on
    /// the gateway's guild objects and this app has never decoded it.
    ///
    /// So the chooser offers what is knowable: take the tag off, or leave it on.
    /// Listing every guild instead would offer a switch that answers 403 on most
    /// of them, which is `INVARIANTS.md` §5.5 — and inventing the list from
    /// mutual servers would be the same guess with extra steps. Decoding the
    /// gateway field is the fix, and it needs a capture.
    /// **Every server that lends a tag, which this could not answer until the
    /// gateway field was decoded.** The note above described the workaround it
    /// replaces: with no list, the chooser could only offer "take the tag off or
    /// leave it on", because inventing candidates from mutual servers would
    /// offer switches that answer 403.
    ///
    /// `guild.profile.tag` rides READY and is what Discord's own client asks —
    /// `guild?.profile?.tag != null` — so the list is exact rather than guessed.
    private var tagOptions: [ServerTagOption] {
        model.guilds.values
            .filter(\.offersTag)
            .map { guild in
                ServerTagOption(
                    id: guild.id,
                    name: guild.name,
                    tag: guild.tag ?? "",
                    badgeURL: guild.tagBadgeHash.flatMap {
                        CDN.guildTagBadge(guildID: guild.id, hash: $0)
                    },
                    iconURL: guild.iconHash.flatMap {
                        CDN.guildIcon(guildID: guild.id, hash: $0, side: 24)
                    },
                    monogram: guild.monogram
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The handoff's own gutter for this column: 28 at its 1,280-point sheet.
    private static let gutter: CGFloat = 22

    /// What a board card is drawn at, and therefore what this column is worth.
    ///
    /// **Discord's own number, measured rather than picked.** Their profile and
    /// this one, captured on the same screen at the same scale: their widget
    /// card comes out at 432 points inside a 961-point modal. A widget takes
    /// whatever column it is given, so the column is derived from the card here
    /// instead of the card being left to fill what the sheet had spare —
    /// `ProfilePresenter.maximumWidth` adds the identity panel to this.
    static let boardWidth: CGFloat = 432
    /// The column with its two gutters, which is what the sheet reserves.
    static let contentWidth: CGFloat = boardWidth + gutter * 2

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
        .modifier(ProfileGroundFill(ground: ground, corner: 0, form: .page))
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
                        set: { chosenTab = $0 }
                    )
                )
            }
            Spacer(minLength: Spacing.base)
            // **Only on the reader's own profile, and only while it is not
            // already open.** Editing somebody else's is not a thing this
            // control could ask for, and a button that toggles a rail already on
            // screen is a second way to say what the rail's own chevron says.
            if profile.isSelf, editor == nil {
                editButton
            }
            // **Never beside the edit button, and the arithmetic is why.** This
            // column is 476 points; the picker alone is 264, and a spelled-out
            // count is another 120. With the pencil as well the row overflows
            // and the control that loses is whichever SwiftUI decides to
            // compress — which was the edit button, silently. On the reader's
            // own profile the count is also the least useful thing here: the
            // Mutuals tab is already titled with it.
            if !profile.mutualServers.isEmpty, editor == nil, !profile.isSelf {
                mutualCount
            }
            closeButton
        }
        .padding(.leading, Self.gutter)
        .padding(.trailing, Spacing.snug)
        .padding(.top, 21)
        .padding(.bottom, 16)
    }

    /// The mutual-servers pill.
    ///
    /// **Three spellings, and the row picks one — it never truncates.** The
    /// comment on `topBar` has the arithmetic: the column is 476 points and the
    /// picker takes what its longest labels need, so a *third* tab pushes the
    /// spelled-out count past the edge and SwiftUI answered by clipping it to
    /// "1 mutual ser…". A truncated count is worse than a short one: the number
    /// is the whole content and the words are only there to say what it counts.
    ///
    /// `ViewThatFits` rather than a measured threshold, because the picker's
    /// width is its own labels' — a constant here would be right for three
    /// English tabs and wrong the moment one of them is a different length.
    private var mutualCount: some View {
        ViewThatFits(in: .horizontal) {
            mutualPill(spelledOut)
            mutualPill("\(profile.mutualServers.count) mutual")
            mutualPill("\(profile.mutualServers.count)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spelledOut))
    }

    private var spelledOut: String {
        profile.mutualServers.count == 1
            ? "1 mutual server"
            : "\(profile.mutualServers.count) mutual servers"
    }

    private func mutualPill(_ label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ground.accent ?? Palette.presenceOnline)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(InkColor.secondary)
                .lineLimit(1)
                // **Fixed, or `ViewThatFits` has nothing to choose between.**
                // A `Text` that will happily truncate reports that it fits at
                // any width, so the first variant always "fits" and the shorter
                // ones are never reached.
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .frame(height: 27)
        .chromeOverMedia(tinted: Palette.flyoutTint)
    }

    /// **A pencil, not a labelled button**, for the width above. It sits beside
    /// the close control, which is the corner people already look in for what to
    /// do with this sheet, and it carries its words in a tooltip and to
    /// VoiceOver rather than in the row.
    private var editButton: some View {
        Button(action: beginEditing) {
            Image(systemName: "pencil")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help("Edit Profile")
        .accessibilityLabel(Text("Edit your profile"))
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
        // sheet's own board, or a tenure badge's page opened from its badge
        // row, sits on top of it and owns Escape while it is there.
        .cancelAction(unless: model.isCovered(.profile))
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

    /// The board, stacked.
    ///
    /// **One column, and the stack is the whole layout.** A `MasonryLayout` sat
    /// here to pack tiles that disagree about height into several columns, and a
    /// span key beside it to let a widget claim the full width. Neither ever
    /// ran: the column is one board card wide by construction — see
    /// `boardWidth` — so the pack had a single column to fill at every width
    /// this sheet can reach, and was a `VStack` with arithmetic in front of it.
    ///
    /// Leading-aligned, because a cover wall reports the width its rows actually
    /// used rather than the one it was offered, and a centred shelf drifts right
    /// as its last row empties.
    @ViewBuilder
    private var boardPane: some View {
        if let editor {
            // **The same tab, not a second surface.** The board is what the
            // reader is editing, so the editor replaces its contents in place —
            // an editor that opened elsewhere would make them close it to check
            // their work.
            BoardEditorPane(editor: editor, board: board, ground: ground)
        } else if let board {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(board.tiles) { tile in
                    BoardSlab(tile: tile, ground: ground, userID: profile.userID)
                }
            }
            .padding(.top, Spacing.base)
        }
    }

    @ViewBuilder
    private var activityPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            // **Every activity, in Discord's order** — `ActivityOrder` — one
            // slab each. Only the first one's buttons and store are fetched,
            // so the rest draw without them rather than with dead ones.
            ForEach(Array(profile.activities.enumerated()), id: \.offset) { index, current in
                ProfileSlab(ground: ground) {
                    CurrentActivityCard(
                        activity: current,
                        buttonURLs: index == 0 ? profile.activityButtonURLs : [],
                        storeOffers: index == 0 ? profile.activityStoreOffers : [],
                        ground: ground,
                        openGame: gameOpener(for: current),
                        applicationIconURL: model.applicationIconURL(
                            current.applicationID, side: Metrics.avatarProfile
                        ),
                        // The slab around it is already the plate.
                        platesItself: false
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
                                    applicationIconURL: model.applicationIconURL(
                                        entry.subject.applicationID,
                                        side: Metrics.activityRecentIcon
                                    ),
                                    // **A game opens its game profile; an
                                    // application opens its own page.** They
                                    // are two different objects and Discord
                                    // draws two different surfaces —
                                    // `/games` answers for Forza and has
                                    // nothing to say about Wordle, which is
                                    // an app. Routing both to the game
                                    // profile opened an empty page for every
                                    // activity that is not a tracked title.
                                    openGame: entry.subject.applicationID.map { id in
                                        model.games[id] != nil
                                            ? { model.openGameProfile(id) }
                                            : { model.activityInfoID = id }
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
    /// them with the count, and it is right.
    ///
    /// A function on the tab rather than a computed property on the sheet, so
    /// the gating is reachable from a test — the decision it makes is invisible
    /// in a rendered view and would otherwise only be checkable by opening
    /// somebody's profile and counting.
    /// - Parameter isEditing: **the Board is always offered while editing.**
    ///   Hiding it on an empty board is right for a reader looking at somebody
    ///   else — a tab promising a surface that does not exist — and exactly
    ///   wrong for the person who came to make one.
    static func available(
        profile: ProfilePresentation,
        board: BoardPresentation?,
        activity: ProfileActivityPresentation,
        isEditing: Bool = false
    ) -> [ProfileTab] {
        var tabs: [ProfileTab] = []
        if isEditing || board?.tiles.isEmpty == false { tabs.append(.board) }
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
