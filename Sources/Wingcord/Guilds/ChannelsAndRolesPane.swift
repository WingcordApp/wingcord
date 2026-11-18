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
                    // **Beside the page, as the guide's do** (Alex,
                    // 2026-11-18): Browse Channels is for looking around, and
                    // a press that left it lost your place in the list. The
                    // column's Open Channel goes all the way.
                    openChannel: { model.previewChannel($0) },
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

/// The page's one piece of floating chrome, on the toolbar row: the tabs at its
/// leading end, the page's name in the middle where every page's is, and the search
/// at its trailing end while there's a list to search (Alex, 2026-11-04: "the picker
/// in the top left, and a native search bar which appears on browsing channels in
/// the top right").
///
/// **The tabs are the system's capsule segmented control** (`SegmentedPicker`,
/// INVARIANTS "The system's own segmented control"), which brings its own
/// material — so it sits outside the `GlassEffectContainer` the search field
/// and the saving spinner share, where they reflow as one when the field
/// appears. The channel count rides in the second segment's title: the system
/// control has no badge, and the number is the reason to look at that tab.
private struct ChannelsAndRolesBar: View {
    @Binding var tab: ChannelsAndRolesPane.Tab
    @Binding var query: String
    var showsTabs: Bool
    var showsSearch: Bool
    var channelCount: Int
    var isSaving: Bool

    @Environment(\.motion) private var motion

    private static let searchWidth: CGFloat = 240

    var body: some View {
        PageHeaderBar {
            if showsTabs {
                SegmentedPicker(options: tabs, selection: $tab)
                    .fixedSize()
            }
        } center: {
            HeaderTitleCapsule()
        } trailing: {
            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, Spacing.base)
                            .frame(height: SearchField.height)
                            .glassEffect(.regular, in: .capsule)
                            .transition(.materialize)
                            .accessibilityLabel("Saving your answers")
                    }
                    if showsSearch {
                        SearchField(prompt: "Search channels", text: $query)
                            .frame(width: Self.searchWidth)
                            .transition(.materialize(from: .trailing, blurring: false))
                    }
                }
            }
        }
        .animation(motion.glassMorph, value: showsSearch)
        .animation(motion.glassMorph, value: isSaving)
    }

    private var tabs: [SegmentedPicker<ChannelsAndRolesPane.Tab>.Option] {
        [
            .init(.customize, "Customize"),
            .init(.browse, channelCount > 0 ? "Browse Channels \(channelCount)" : "Browse Channels"),
        ]
    }
}

// MARK: - Customize

private struct CustomizeTab: View {
    var presentation: ChannelsAndRolesPresentation
    /// Whether the column can carry the aside beside the questions.
    var isWide: Bool
    var toggleOption: (UInt64, UInt64) -> Void

    /// The tab settles in as the guide does (`SurfaceEntrance`) — again on
    /// every switch back to it, which is a new arrival.
    @State private var hasAppeared = false

    var body: some View {
        SurfaceHeading(
            title: "Customize",
            detail: "Answer these to unlock more channels and pick up roles.",
            badge: nil
        )
        .modifier(SurfaceEntrance(index: 0, isShown: hasAppeared))
        .onAppear { hasAppeared = true }

        // **The narrow arrangement puts the profile FIRST.** It is the answer to
        // "what do these questions do to me", and below two prompts on a phone-
        // width column it is an answer nobody scrolls to.
        if !isWide, let me = presentation.me {
            MyProfileAside(me: me)
                .modifier(SurfaceEntrance(index: 1, isShown: hasAppeared))
        }

        HStack(alignment: .top, spacing: Spacing.group) {
            VStack(alignment: .leading, spacing: Spacing.group) {
                Questions(presentation: presentation, toggleOption: toggleOption, isShown: hasAppeared)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isWide, let me = presentation.me {
                MyProfileAside(me: me)
                    .frame(width: Proportions.surfaceAsideWidth)
                    .modifier(SurfaceEntrance(index: 1, isShown: hasAppeared))
            }
        }
    }
}

/// The prompts, or what stands in for them.
private struct Questions: View {
    var presentation: ChannelsAndRolesPresentation
    var toggleOption: (UInt64, UInt64) -> Void
    /// The tab's arrival, which each question takes a beat after the last.
    var isShown = true

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
            ForEach(Array(presentation.prompts.enumerated()), id: \.element.id) { index, prompt in
                PromptSection(prompt: prompt, toggleOption: toggleOption)
                    .modifier(SurfaceEntrance(index: index + 2, isShown: isShown))
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
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let bio = me.bio {
                        ProseText(
                            markdown: bio,
                            font: .system(.body),
                            pointSize: ProseText.bioPointSize,
                            color: InkColor.primary,
                            emojiSide: ProseText.bioEmojiSide
                        )
                        .lineLimit(6)
                    }

                    if !me.roles.isEmpty {
                        SurfaceDivider(leading: 0)
                            .padding(.vertical, Spacing.tight)
                        Text("Roles")
                            .font(Typeface.sectionHeader)
                            .foregroundStyle(Ink.secondary)
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
        GridItem(.adaptive(minimum: 280), spacing: Spacing.snug, alignment: .top)
    ]

    var body: some View {
        SurfaceSection(
            title: prompt.title,
            detail: prompt.guidance,
            note: prompt.isRequired ? "Required" : nil
        ) {
            LazyVGrid(columns: Self.columns, spacing: Spacing.snug) {
                ForEach(prompt.options) { option in
                    OptionChip(option: option, isSingleSelect: prompt.isSingleSelect, toggle: toggleOption)
                }
            }
        }
    }
}

/// One answer.
///
/// **The whole card is the control**, which is why the selected state is the
/// card's own tint and edge rather than only a mark in a corner: at a glance
/// somebody has to be able to see which of six they picked without reading six
/// corners.
///
/// **Frosted like every card on the page** (Alex, 2026-11-17): it was the
/// theme's opaque surface, which on a dark theme came out as a black slab
/// beside the translucent profile card. Checkboxes where a question takes
/// several answers, radios where it takes one — Discord's own marks.
private struct OptionChip: View {
    var option: ChannelsAndRolesPresentation.Option
    var isSingleSelect: Bool
    var toggle: (UInt64, UInt64) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.glass, style: .continuous) }

    var body: some View {
        Button {
            toggle(option.id, option.promptID)
        } label: {
            HStack(alignment: .center, spacing: Spacing.snug) {
                OptionIconTile(glyph: option.glyph, isSelected: option.isSelected)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if option.unlocks != nil || (option.memberCount ?? 0) > 0 {
                        HStack(spacing: Spacing.base) {
                            if let unlocks = option.unlocks {
                                // The role's own colour, the only colour on the
                                // card that is not the app's.
                                HStack(spacing: 5) {
                                    if let value = option.roleColorValue {
                                        Circle()
                                            .fill(Color(hex: value))
                                            .frame(width: 7, height: 7)
                                    }
                                    Text(unlocks)
                                        .font(.system(.caption, weight: .medium))
                                        .foregroundStyle(Ink.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, Spacing.base)
                                .frame(height: 20)
                                .background(
                                    (option.roleColorValue.map { Color(hex: $0) } ?? Palette.accent).opacity(0.16),
                                    in: .capsule
                                )
                            }
                            if let count = option.memberCount, count > 0 {
                                Label {
                                    Text(count, format: .number.notation(.compactName))
                                } icon: {
                                    Image(systemName: "person.2.fill")
                                }
                                .labelStyle(.titleAndIcon)
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(Ink.secondary)
                                .help("\(count) members have this role")
                            }
                        }
                        .padding(.top, 3)
                    }
                }

                Spacer(minLength: Spacing.tight)

                OptionSelectionMark(isSelected: option.isSelected, isSingleSelect: isSingleSelect, isHighlighted: isHovering)
            }
            .padding(Spacing.margin)
            // **Fills the grid row's height.** `LazyVGrid` sizes a row to its
            // tallest child and top-aligns the rest, so a card with no unlocks
            // line beside one that has both would leave a ragged foot.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .structuralSurface(in: shape)
            .overlay {
                shape.fill(option.isSelected ? Palette.accent.opacity(0.14) : (isHovering ? Palette.hoverFill : .clear))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(
                    option.isSelected
                        ? AnyShapeStyle(Palette.accent.opacity(0.75))
                        : AnyShapeStyle(isHovering ? Ink.tertiary : Ink.quaternary),
                    lineWidth: option.isSelected ? 1.5 : 1
                )
            }
            // A soft accent glow under a picked card — a fill behind the card,
            // never a shadow on it: a shadow takes the card offscreen, where its
            // material has nothing behind it to frost and paints black.
            .background {
                if option.isSelected {
                    shape.fill(Palette.accent.opacity(0.28))
                        .blur(radius: 12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(shape)
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
}

/// An answer's emoji or symbol, on a tile that takes the accent once picked.
private struct OptionIconTile: View {
    var glyph: SurfaceGlyph
    var isSelected: Bool

    var body: some View {
        SurfaceGlyphView(glyph: glyph, isEmphasised: isSelected)
            .scaleEffect(1.15)
            .frame(width: 42, height: 42)
            .background(
                isSelected ? AnyShapeStyle(Palette.accent.opacity(0.2)) : AnyShapeStyle(Palette.hoverFill),
                in: .rect(cornerRadius: 11, style: .continuous)
            )
    }
}

/// A checkbox where the question takes several answers, a radio where it takes
/// one — filled with the accent once picked.
///
/// **The tick draws itself in** (Alex, 2026-11-18: "add the animated
/// checkmark"): SF Symbols' draw animation — the stroke the native checkbox
/// draws on macOS 26 — on the box's own tick, which draws back off when the
/// answer is taken away. The box fills on a small spring; a radio's dot
/// grows in. Under Reduce Motion the tick and the dot simply appear.
private struct OptionSelectionMark: View {
    var isSelected: Bool
    var isSingleSelect: Bool
    /// Under the pointer: the empty box's edge comes up.
    var isHighlighted = false

    @Environment(\.motion) private var motion

    private static let side: CGFloat = 20

    var body: some View {
        let shape = isSingleSelect
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        ZStack {
            shape
                .fill(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear))
            shape
                .stroke(isSelected ? Color.clear : isHighlighted ? Ink.secondary : Ink.tertiary, lineWidth: 1.5)
            if isSingleSelect {
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .scaleEffect(isSelected ? 1 : 0.2)
                    .opacity(isSelected ? 1 : 0)
            } else if motion.reduceMotion {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isSelected ? 1 : 0)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    // Drawn off while unpicked; picking draws the stroke on.
                    .symbolEffect(.drawOff, isActive: !isSelected)
            }
        }
        .frame(width: Self.side, height: Self.side)
        // A small pop as the answer changes, then back to its size.
        .keyframeAnimator(initialValue: 1.0, trigger: isSelected) { content, scale in
            content.scaleEffect(motion.reduceMotion ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(1.16, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isSelected)
        .accessibilityHidden(true)
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

    /// The tab settles in as the guide does (`SurfaceEntrance`).
    @State private var hasAppeared = false

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
        .modifier(SurfaceEntrance(index: 0, isShown: hasAppeared))
        .onAppear { hasAppeared = true }

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
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                BrowseSection(
                    category: category,
                    offersFollowing: presentation.offersFollowing,
                    openChannel: openChannel,
                    toggleFollowed: toggleFollowed
                )
                .modifier(SurfaceEntrance(index: index + 1, isShown: hasAppeared))
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
        VStack(alignment: .leading, spacing: Spacing.base) {
            BrowseCategoryHeader(
                title: category.title ?? "Channels",
                count: category.channels.count
            ) {
                // Only where the category is real — the loose rows above the
                // first one belong to nothing, so there is nothing to follow.
                if offersFollowing, let channelID = category.channelID {
                    FollowCategoryToggle(
                        isOn: category.isFollowed,
                        isWorking: category.isFollowWorking,
                        action: { toggleFollowed(channelID) }
                    )
                }
            }
            SurfaceCard {
                ForEach(Array(category.channels.enumerated()), id: \.element.id) { index, channel in
                    if index > 0 { SurfaceDivider(leading: BrowseRow.textLeading) }
                    BrowseRow(
                        channel: channel,
                        offersFollowing: offersFollowing,
                        openChannel: openChannel,
                        toggleFollowed: toggleFollowed
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A category's name, how many channels it holds, and its Follow switch, on
/// one line over its card.
///
/// **The switch is in the line, not laid over it.** It was an overlay on the
/// section's top corner, which a long category name ran underneath.
private struct BrowseCategoryHeader<Accessory: View>: View {
    var title: String
    var count: Int
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Text(count, format: .number)
                .font(.system(.caption, weight: .semibold).monospacedDigit())
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 18)
                .background(Palette.hoverFill, in: .capsule)
                .accessibilityLabel(Text("\(count) channels"))
            Spacer(minLength: Spacing.base)
            accessory
        }
        .padding(.horizontal, Spacing.tight)
        .accessibilityElement(children: .contain)
    }
}

/// "Follow" — a real `Toggle`, at the system's size and with the system's
/// switch.
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
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Text("Follow")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isWorking)
        .opacity(isWorking ? 0.5 : 1)
        .help(isOn ? "Unfollow this category" : "Follow this category")
        .accessibilityLabel(Text("Follow category"))
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

    static let tileSide: CGFloat = 32
    /// Where a row's words start: what the divider between two rows clears.
    static let textLeading = Spacing.margin + tileSide + Spacing.snug

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
                HStack(alignment: channel.topic == nil ? .center : .top, spacing: Spacing.snug) {
                    BrowseChannelTile(symbolName: channel.symbolName, isUnread: channel.isUnread)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                            Text(channel.name)
                                // Unread bolds the name rather than adding a
                                // second mark, exactly as the sidebar's rows do.
                                .font(channel.isUnread
                                    ? Typeface.rowTitleUnread
                                    : Font.system(.body, weight: .medium))
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            Spacer(minLength: Spacing.base)
                            if let activity = channel.lastActivity {
                                // `Text` with a relative format, so the phrasing
                                // is the locale's and the string is built by the
                                // framework rather than by a formatter this page
                                // would have to own.
                                Text(activity, format: .relative(presentation: .named))
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundStyle(Ink.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if let topic = channel.topic {
                            Text(topic)
                                .font(.system(.callout))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
        // Discord's unread pill, at the card's edge where the sidebar's sits at
        // the column's: half of it, the card's clip takes the rest.
        .overlay(alignment: .leading) {
            if channel.isUnread {
                Capsule()
                    .fill(Ink.primary)
                    .frame(width: 8, height: 8)
                    .offset(x: -4)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityValue(channel.isUnread ? Text("Unread") : Text(""))
    }
}

/// A channel's mark on a tile, as the sidebar draws it bare: lit while there is
/// something new in it.
private struct BrowseChannelTile: View {
    var symbolName: String
    var isUnread: Bool

    var body: some View {
        Image(symbol: symbolName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isUnread ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
            .frame(width: BrowseRow.tileSide, height: BrowseRow.tileSide)
            .background(Palette.hoverFill, in: .rect(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The tick beside a browse row: the same box the Customize tab's answers
/// draw, so one page has one checkbox.
///
/// A drawn control rather than a `Toggle(.checkbox)`, and for the one reason
/// that outweighs the switch's: this sits beside a row that is itself a button,
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

    var body: some View {
        Button(action: action) {
            OptionSelectionMark(isSelected: isOn, isSingleSelect: false, isHighlighted: isHovering)
                // The press reaches a little past the box, to the 28 points a
                // pointer needs; the box stays its drawn size.
                .frame(width: 28, height: 28)
                .contentShape(.rect)
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

