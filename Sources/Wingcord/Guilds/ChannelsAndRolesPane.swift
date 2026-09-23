import SwiftUI
import WingcordCore

/// Channels & Roles — the server's questions, and its whole channel list.
///
/// One page with two halves rather than two destinations, because they answer
/// the same question from two directions: *what is in here, and how do I get to
/// more of it.* A server that asks nothing collapses to the second half and the
/// segmented control disappears with it — a control with one segment is a label
/// that looks pressable.
struct ChannelsAndRolesContainer: View {
    /// Which row was clicked. `browseChannels` is the same page opened by a
    /// server with no questions, so it starts — and stays — on the list.
    var surface: GuildSurface

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let presentation = model.channelsAndRolesPresentation {
                ChannelsAndRolesPane(
                    presentation: presentation,
                    startsOnBrowse: surface == .browseChannels,
                    toggleOption: { model.toggleOnboardingOption($0, inPrompt: $1) },
                    openChannel: { model.openChannelFromSurface($0) },
                    toggleFollowed: { model.toggleChannelFollowed($0) }
                )
                .equatable()
            }
        }
        // The counts are an embellishment on a chip and the largest of the five
        // answers this server can give — nearly two hundred entries. Asked for
        // by somebody opening the page, never with the guild.
        //
        // **Keyed on the questions as well as the server**, because the
        // questions arrive on their own route: keyed on the guild alone the task
        // would run once, before onboarding had answered, decide there was
        // nothing to count, and never run again.
        .task(id: countsKey) {
            guard countsKey.asksQuestions, let guildID = countsKey.guildID else { return }
            model.sessionController.loadRoleMemberCounts(guildID)
            // The reader's own bio is only on the profile route — the member
            // record carries a nickname, an avatar and roles and nothing else —
            // so the aside asks for it once. Deduped by the controller, and
            // cached on the account for the session.
            if let userID = model.currentUserID {
                model.sessionController.loadProfile(of: userID, inGuild: guildID)
            }
        }
    }

    private var countsKey: CountsKey {
        let guildID = model.selectedGuildID
        return CountsKey(
            guildID: guildID,
            asksQuestions: guildID.flatMap {
                model.guildOnboardings[$0]?.answerablePrompts.isEmpty == false
            } ?? false
        )
    }

    private struct CountsKey: Hashable {
        var guildID: GuildID?
        var asksQuestions: Bool
    }
}

struct ChannelsAndRolesPane: View, Equatable {
    var presentation: ChannelsAndRolesPresentation
    var startsOnBrowse: Bool

    static func == (lhs: ChannelsAndRolesPane, rhs: ChannelsAndRolesPane) -> Bool {
        lhs.presentation == rhs.presentation && lhs.startsOnBrowse == rhs.startsOnBrowse
    }

    var toggleOption: (UInt64, UInt64) -> Void = { _, _ in }
    var openChannel: (ChannelID) -> Void = { _ in }
    var toggleFollowed: (ChannelID) -> Void = { _ in }

    enum Tab: Hashable { case customize, browse }

    /// The narrowest **pane** that can carry the aside beside the questions.
    /// Below it the aside goes above them instead.
    ///
    /// Derived rather than picked, and from the pane's width because that is
    /// what is measured: the page's two margins, the aside, the gap, and the
    /// narrowest a two-up column of option chips can be.
    private static let asideThreshold: CGFloat =
        Spacing.group * 2 + Proportions.surfaceAsideWidth + Spacing.group + 520

    @Environment(\.motion) private var motion
    @State private var isWide = true
    @State private var tab: Tab = .customize
    @State private var query = ""
    /// The query, folded once per keystroke rather than once per row. A
    /// five-hundred-channel server otherwise case-folds and allocates a string
    /// per row per character typed.
    @State private var foldedQuery = ""

    /// Which half is actually showing.
    ///
    /// Derived rather than stored, so a server whose questions arrive while the
    /// page is open cannot leave the reader on a tab that no longer exists.
    private var resolvedTab: Tab {
        presentation.asksQuestions ? tab : .browse
    }

    var body: some View {
        SurfacePage(measure: Proportions.surfaceColumnWide) {
            switch resolvedTab {
            case .customize:
                CustomizeTab(
                    presentation: presentation,
                    isWide: isWide,
                    toggleOption: toggleOption
                )
            case .browse:
                BrowseTab(
                    presentation: presentation,
                    foldedQuery: foldedQuery,
                    openChannel: openChannel,
                    toggleFollowed: toggleFollowed
                )
            }
        }
        // A floating bar, not a hand-drawn band: `safeAreaBar` registers it, so
        // the reservation and the bar cannot disagree — which is the bug every
        // hand-reserved clearance eventually grows.
        .floatingTopBar {
            ChannelsAndRolesBar(
                tab: $tab,
                query: $query,
                showsTabs: presentation.asksQuestions,
                showsSearch: resolvedTab == .browse,
                channelCount: presentation.channelCount,
                isSaving: presentation.isSaving
            )
            .surfaceColumn(Proportions.surfaceColumnWide)
            .padding(.bottom, Spacing.base)
        }
        // **One measurement, guarded and unanimated.** The aside is dropped
        // below the questions rather than squeezed beside them once the column
        // cannot give both room, and a `@State` write of an equal value still
        // invalidates — this fires on every frame of a window resize.
        .background(alignment: .top) {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    let next = width >= Self.asideThreshold
                    guard isWide != next else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isWide = next }
                }
                .allowsHitTesting(false)
        }
        .onAppear(perform: resetTab)
        // The pane's view type is stable across servers, so its `@State` can
        // outlive the server it belongs to. Resetting on the guild is what stops
        // a search typed in one server filtering another's channel list.
        .onChange(of: presentation.guildID) { _, _ in
            resetTab()
            query = ""
        }
        .onChange(of: query) { _, value in
            // Guarded: a `@State` write of an equal value still invalidates, and
            // this fires on every keystroke.
            let folded = value.lowercased()
            guard folded != foldedQuery else { return }
            foldedQuery = folded
        }
        .animation(motion.standard, value: resolvedTab)
    }

    private func resetTab() {
        let next: Tab = startsOnBrowse || !presentation.asksQuestions ? .browse : .customize
        guard tab != next else { return }
        tab = next
    }
}

// MARK: - The bar

/// The page's one piece of floating chrome.
///
/// **One glass body per control, merged in a container** — the segmented control
/// and the search field are two surfaces that reflow as one when the second
/// appears, which is what `GlassEffectContainer` is for. Neither carries a fill
/// behind its material: the selected segment's pill is a *region inside* the
/// segmented control's own glass, exactly as the now bar's controls are regions
/// inside the bar's.
private struct ChannelsAndRolesBar: View {
    @Binding var tab: ChannelsAndRolesPane.Tab
    @Binding var query: String
    var showsTabs: Bool
    var showsSearch: Bool
    var channelCount: Int
    var isSaving: Bool

    @Environment(\.motion) private var motion

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                if showsTabs {
                    SegmentedTabs(tab: $tab, channelCount: channelCount)
                }
                if showsSearch {
                    ChannelSearchField(query: $query)
                }
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, Spacing.base)
                        .frame(height: Metrics.control + Spacing.base)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.materialize)
                        .accessibilityLabel("Saving your answers")
                }
                Spacer(minLength: 0)
            }
        }
        .animation(motion.glassMorph, value: showsSearch)
        .animation(motion.glassMorph, value: isSaving)
    }
}

/// Two segments, one travelling pill.
///
/// The pill is a plain tinted capsule inside the control's material rather than
/// a second glass body — §4 rule 2 — and it travels with
/// `matchedGeometryEffect`, which is the same idiom the full profile's tab
/// underline uses. A `glassEffectID` morph is the alternative and is wrong here:
/// the pill sits *behind* two labels that are ordinary siblings, and a
/// container promotes its glass elements above them.
private struct SegmentedTabs: View {
    @Binding var tab: ChannelsAndRolesPane.Tab
    var channelCount: Int

    @Environment(\.motion) private var motion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            segment("Customize", value: .customize, badge: nil)
            segment("Browse Channels", value: .browse, badge: channelCount)
        }
        .padding(3)
        .frame(height: Metrics.control + Spacing.base)
        .glassEffect(.regular, in: .capsule)
        .animation(motion.glassMorph, value: tab)
    }

    private func segment(
        _ title: String,
        value: ChannelsAndRolesPane.Tab,
        badge: Int?
    ) -> some View {
        let isSelected = tab == value
        return Button {
            guard tab != value else { return }
            tab = value
        } label: {
            HStack(spacing: Spacing.tight) {
                Text(title)
                    .font(.system(.callout, weight: isSelected ? .semibold : .regular))
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(Typeface.badge)
                        .foregroundStyle(Ink.tertiary)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
            .padding(.horizontal, Spacing.snug)
            .frame(maxHeight: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Palette.selectionFill)
                        .matchedGeometryEffect(id: "segment", in: pill)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The search field.
///
/// The glyph and the field are **inside** the glass view's content, which is
/// what §4 rule 4 requires: anything that must sit over glass goes in before the
/// modifier, because an overlay attached outside draws underneath.
private struct ChannelSearchField: View {
    @Binding var query: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField("Search channels", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.callout))
                .foregroundStyle(Ink.primary)
                .focused($isFocused)
                .onSubmit { isFocused = false }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(width: 200, height: Metrics.control + Spacing.base)
        .glassEffect(.regular, in: .capsule)
        // A search field never moves, so it never picks up the system's own
        // specular response as it travels — on a near-black ground that leaves a
        // capsule with no edge at all. This is the still-life version.
        .specularEdge()
        .transition(.materialize)
    }
}

// MARK: - Customize

private struct CustomizeTab: View {
    var presentation: ChannelsAndRolesPresentation
    /// Whether the column can carry the aside beside the questions.
    var isWide: Bool
    var toggleOption: (UInt64, UInt64) -> Void

    var body: some View {
        SurfaceHeading(
            title: "Customize",
            detail: "Answer these to unlock more channels and pick up roles.",
            badge: nil
        )

        // **The narrow arrangement puts the profile FIRST.** It is the answer to
        // "what do these questions do to me", and below two prompts on a phone-
        // width column it is an answer nobody scrolls to.
        if !isWide, let me = presentation.me {
            MyProfileAside(me: me)
        }

        HStack(alignment: .top, spacing: Spacing.group) {
            VStack(alignment: .leading, spacing: Spacing.group) {
                Questions(presentation: presentation, toggleOption: toggleOption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isWide, let me = presentation.me {
                MyProfileAside(me: me)
                    .frame(width: Proportions.surfaceAsideWidth)
            }
        }
    }
}

/// The prompts, or what stands in for them.
private struct Questions: View {
    var presentation: ChannelsAndRolesPresentation
    var toggleOption: (UInt64, UInt64) -> Void

    var body: some View {
        if presentation.prompts.isEmpty {
            if presentation.isLoading {
                SurfaceLoadingState(message: "Loading this server's questions…")
            } else {
                SurfaceEmptyState(
                    symbol: "questionmark.circle",
                    title: "No questions",
                    detail: "This server does not ask anything before you join in."
                )
            }
        } else {
            ForEach(presentation.prompts) { prompt in
                PromptSection(prompt: prompt, toggleOption: toggleOption)
            }
        }
    }
}

/// The reader, as this server sees them.
///
/// **It is the point of the page in one card.** Every question above it is a
/// question about what the reader wants to be here, and this is the answer —
/// which is why a role granted by an answer already given appears here before
/// the gateway has confirmed it.
private struct MyProfileAside: View {
    var me: GuildSelfPresentation

    var body: some View {
        // No note. The bar already shows a spinner while a ballot is being
        // written, and two indicators for one state is one of them being
        // ignored — and a role granted by an answer already sent is not
        // "pending" in any sense the reader can act on: if the write fails the
        // answer rolls back and takes the role with it.
        SurfaceSection(
            title: "My Profile",
            detail: "How you look to everyone else in this server."
        ) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    AvatarView(
                        url: me.avatarURL,
                        monogram: me.monogram,
                        side: Metrics.avatarProfile
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(me.name)
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if let accountName = me.accountName {
                            Text(accountName)
                                .font(.system(.caption))
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                        }
                    }

                    if let bio = me.bio {
                        Text(bio)
                            .font(.system(.callout))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !me.roles.isEmpty {
                        SurfaceDivider(leading: 0)
                            .padding(.vertical, Spacing.tight)
                        Text("Roles")
                            .font(Typeface.sectionHeader)
                            .foregroundStyle(Ink.tertiary)
                        SurfaceRoleFlow(roles: me.roles)
                    }
                }
                .padding(Spacing.margin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PromptSection: View {
    var prompt: ChannelsAndRolesPresentation.Prompt
    var toggleOption: (UInt64, UInt64) -> Void

    /// Two up at the page's measure, one up when a large text size takes the
    /// room. Adaptive rather than a fixed count, so an accessibility size gets
    /// wider chips instead of clipped ones.
    private static let columns = [
        GridItem(.adaptive(minimum: 260), spacing: Spacing.base, alignment: .top)
    ]

    var body: some View {
        SurfaceSection(
            title: prompt.title,
            detail: prompt.guidance,
            note: prompt.isRequired ? "Required" : nil
        ) {
            LazyVGrid(columns: Self.columns, spacing: Spacing.base) {
                ForEach(prompt.options) { option in
                    OptionChip(option: option, toggle: toggleOption)
                }
            }
        }
    }
}

/// One answer.
///
/// **The whole chip is the control**, which is why the selected state is the
/// chip's own fill and stroke rather than only a tick in a corner: at a glance
/// somebody has to be able to see which of six they picked without reading six
/// corners.
private struct OptionChip: View {
    var option: ChannelsAndRolesPresentation.Option
    var toggle: (UInt64, UInt64) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button {
            toggle(option.id, option.promptID)
        } label: {
            HStack(alignment: .top, spacing: Spacing.snug) {
                SurfaceGlyphView(glyph: option.glyph, isEmphasised: option.isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let unlocks = option.unlocks {
                        HStack(spacing: Spacing.tight) {
                            // The role's own colour, and the only colour on the
                            // chip that is not the app's. A role with no colour
                            // set draws no dot rather than a grey one.
                            if let value = option.roleColorValue {
                                Circle()
                                    .fill(Color(hex: value))
                                    .frame(width: 6, height: 6)
                            }
                            Text(unlocks)
                                .font(.system(.caption))
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                            if let count = option.memberCount, count > 0 {
                                Text("·")
                                    .font(.system(.caption))
                                    .foregroundStyle(Ink.quaternary)
                                Text("\(count, format: .number.notation(.compactName))")
                                    .font(.system(.caption))
                                    .foregroundStyle(Ink.quaternary)
                            }
                        }
                        .padding(.top, 1)
                    }
                }

                Spacer(minLength: Spacing.tight)

                Image(systemName: option.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(
                        option.isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.quaternary)
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.top, 4)
            }
            .padding(Spacing.snug)
            // **Fills the grid row's height.** `LazyVGrid` sizes a row to its
            // tallest child and top-aligns the rest, so an option with no
            // unlocks line beside one that has both leaves a ragged foot —
            // which reads as a layout that could not decide rather than as two
            // chips of different weight.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .strokeBorder(
                        option.isSelected ? AnyShapeStyle(Palette.accent.opacity(0.55)) : AnyShapeStyle(Ink.quaternary),
                        lineWidth: 1
                    )
            }
            .contentShape(.rect(cornerRadius: Radius.glass))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.standard, value: option.isSelected)
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityLabel(Text(option.title))
        .accessibilityValue(Text(option.isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(option.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if option.isSelected { return Palette.accent.opacity(0.16) }
        return isHovering ? Palette.hoverFill : Palette.surface
    }
}

// MARK: - Browse

private struct BrowseTab: View {
    var presentation: ChannelsAndRolesPresentation
    var foldedQuery: String
    var openChannel: (ChannelID) -> Void
    var toggleFollowed: (ChannelID) -> Void

    /// The list, filtered.
    ///
    /// A `let` derived in `body` rather than a cache in `@State`: the query is a
    /// keystroke away from changing, and a cached collection with no explicit
    /// invalidation is how a list goes stale. The rows carry a pre-folded search
    /// key, so a pass over five hundred of them is a substring scan with no
    /// allocation.
    private var matches: [ChannelsAndRolesPresentation.BrowseCategory] {
        guard !foldedQuery.isEmpty else { return presentation.categories }
        var result: [ChannelsAndRolesPresentation.BrowseCategory] = []
        for category in presentation.categories {
            let channels = category.channels.filter { $0.matches(foldedQuery) }
            guard !channels.isEmpty else { continue }
            var trimmed = category
            trimmed.channels = channels
            result.append(trimmed)
        }
        return result
    }

    var body: some View {
        SurfaceHeading(
            title: "Browse Channels",
            detail: presentation.offersFollowing
                ? "Everything you can see. Unfollow a channel to take it out of your list."
                : "Everything in this server you can see, and when it was last busy.",
            // The segmented control already carries the count when it is there,
            // and a page that says ten twice has said it once too often.
            badge: presentation.asksQuestions || presentation.channelCount == 0
                ? nil
                : "\(presentation.channelCount)"
        )

        let categories = matches
        if categories.isEmpty {
            SurfaceEmptyState(
                symbol: foldedQuery.isEmpty ? "tray" : "magnifyingglass",
                title: foldedQuery.isEmpty ? "Nothing to browse" : "No matches",
                detail: foldedQuery.isEmpty
                    ? "There are no channels here you can see."
                    : "No channel's name or topic matches that."
            )
        } else {
            ForEach(categories) { category in
                BrowseSection(
                    category: category,
                    offersFollowing: presentation.offersFollowing,
                    openChannel: openChannel,
                    toggleFollowed: toggleFollowed
                )
            }
        }
    }
}

private struct BrowseSection: View {
    var category: ChannelsAndRolesPresentation.BrowseCategory
    var offersFollowing: Bool
    var openChannel: (ChannelID) -> Void
    var toggleFollowed: (ChannelID) -> Void

    var body: some View {
        SurfaceSection(title: category.title ?? "Channels") {
            SurfaceCard {
                ForEach(Array(category.channels.enumerated()), id: \.element.id) { index, channel in
                    if index > 0 { SurfaceDivider() }
                    BrowseRow(
                        channel: channel,
                        offersFollowing: offersFollowing,
                        openChannel: openChannel,
                        toggleFollowed: toggleFollowed
                    )
                }
            }
        }
        // The switch rides the heading, which is where the thing it governs is
        // named. Only where the category is real — the loose rows above the
        // first one belong to nothing, so there is nothing to follow.
        .overlay(alignment: .topTrailing) {
            if offersFollowing, let channelID = category.channelID {
                FollowCategoryToggle(
                    isOn: category.isFollowed,
                    isWorking: category.isFollowWorking,
                    action: { toggleFollowed(channelID) }
                )
            }
        }
    }
}

/// "Follow Category" — a real `Toggle`, at the system's size and with the
/// system's switch.
///
/// **Not a hand-drawn capsule.** A switch is a control macOS already draws, and
/// one built by hand loses Increase Contrast, the accent colour the reader
/// chose, and every keyboard affordance a `Toggle` brings. The binding is
/// derived rather than stored: the truth is the store's follow set, and a local
/// `@State` mirror is a second copy to keep in step.
private struct FollowCategoryToggle: View {
    var isOn: Bool
    var isWorking: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text("Follow category")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Toggle("Follow category", isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isWorking)
                .opacity(isWorking ? 0.5 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows new channels added to this category"))
    }
}

private struct BrowseRow: View {
    var channel: ChannelsAndRolesPresentation.BrowseChannel
    var offersFollowing: Bool
    var openChannel: (ChannelID) -> Void
    var toggleFollowed: (ChannelID) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        // **The checkbox is a SIBLING of the row's button, not an overlay on
        // it.** Two reasons, and the first is visible: an overlay does not
        // reserve width, so the row's own trailing text — the relative time —
        // lays out underneath the tick. The second is that a control nested
        // inside another control gives the outer one the click, and a tick that
        // opened the channel instead of ticking is the worst of both.
        HStack(spacing: 0) {
            Button {
                openChannel(channel.id)
            } label: {
                HStack(alignment: .top, spacing: Spacing.snug) {
                    SurfaceGlyphView(glyph: .symbol(channel.symbolName))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            // Unread bolds the name rather than adding a second
                            // mark, exactly as the sidebar's rows do.
                            .font(channel.isUnread
                                ? Typeface.rowTitleUnread
                                : Font.system(.body, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if let topic = channel.topic {
                            Text(topic)
                                .font(.system(.caption))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: Spacing.base)

                    if let activity = channel.lastActivity {
                        // `Text` with a relative format, so the phrasing is the
                        // locale's and the string is built by the framework
                        // rather than by a formatter this page would have to own.
                        Text(activity, format: .relative(presentation: .named))
                            .font(.system(.caption))
                            .foregroundStyle(Ink.quaternary)
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                }
                .padding(.leading, Spacing.margin)
                .padding(.trailing, offersFollowing ? Spacing.snug : Spacing.margin)
                .padding(.vertical, Spacing.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if offersFollowing {
                FollowCheckbox(
                    isOn: channel.isFollowed,
                    isLocked: channel.isFollowLocked,
                    isWorking: channel.isFollowWorking,
                    name: channel.name,
                    action: { toggleFollowed(channel.id) }
                )
                .padding(.trailing, Spacing.margin)
            }
        }
        // On the row rather than on the button, so the highlight runs under the
        // checkbox too and the row still reads as one object.
        .background(Palette.hoverFill.opacity(isHovering ? 1 : 0))
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .contain)
    }
}

/// The tick beside a browse row.
///
/// A drawn control rather than a `Toggle(.checkbox)`, and for the one reason
/// that outweighs the switch's: this sits inside a row that is itself a button,
/// and it has to be visibly the *only* thing its own press does. A system
/// checkbox brings a label slot and a focus ring sized for a form; here the
/// square is the whole control, and it takes the accent the same way every
/// selected thing in this app does.
private struct FollowCheckbox: View {
    var isOn: Bool
    /// Whether the category above decided this, in which case the tick is shown
    /// and cannot be pressed. **Dimmed rather than hidden**: the reader still
    /// needs to see that the channel is in, and an empty slot beside a followed
    /// category would read as it being out.
    var isLocked: Bool
    var isWorking: Bool
    var name: String
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let side: CGFloat = 18

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.hoverFill))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : isHovering ? checkEdgeHovered : checkEdge)
                }
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.opacity)
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .contentShape(.rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(isWorking || isLocked)
        .opacity(isWorking || isLocked ? 0.45 : 1)
        // Guard the modifier, not the closure: a locked tick can never
        // highlight, and `.onHover` on it is an AppKit tracking area whose
        // geometry is re-derived on every frame of every scroll for nothing.
        .modifier(CheckboxHover(isEnabled: !isLocked && !isWorking, isHovering: $isHovering))
        .animation(motion.standard, value: isOn)
        .animation(motion.fadeQuick, value: isHovering)
        // **Worded for what this client can verify.** The write is real and it
        // syncs — Discord's own clients take an unfollowed channel out of the
        // sidebar on the strength of it. Wingcord's sidebar deliberately does
        // not act on it yet, because the one thing the captures do not settle is
        // what a channel with NO override means, and guessing that wrong hides
        // channels. So the label says what is certain.
        .help(helpText)
        .accessibilityLabel(Text("Follow \(name)"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityHint(isLocked ? Text("Set by the category above") : Text(""))
        .accessibilityAddTraits(.isButton)
    }

    /// **Worded for what this client can verify.** The write is real and it
    /// syncs; what the tooltip must not claim is anything about another client.
    private var helpText: String {
        if isLocked { return "Followed with its category" }
        return isOn ? "Unfollow #\(name)" : "Follow #\(name)"
    }
}

/// Installs a tracking area only where a highlight can happen.
private struct CheckboxHover: ViewModifier {
    var isEnabled: Bool
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
        } else {
            content
        }
    }
}

/// An unchecked box's edge, at rest and under the pointer: light in a dark room,
/// shade in a light one.
private let checkEdge = Color.relative(dark: 0.18, light: 0.20)
private let checkEdgeHovered = Color.relative(dark: 0.35, light: 0.32)
