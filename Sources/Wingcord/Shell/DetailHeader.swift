import SwiftUI
import WingcordCore

/// The detail column's top row, level with the traffic lights.
///
/// Three groups at most, as the HIG asks of a toolbar: the sidebar's controls
/// while the sidebar is away (they live in the panel otherwise), the title in
/// the middle, and the channel's acts with search at the trailing end. Every
/// one of them is also a menu-bar command.
struct DetailHeader: View {
    var layout: ShellLayout

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// What a forum's row is laid out against. Only a resize or another channel
    /// moves any of them, and each is read from the layout that already happened.
    @State private var rowWidth: CGFloat = 0
    @State private var titleWidth: CGFloat = 0
    @State private var toolsWidth: CGFloat = 0
    /// A forum's search is open, which takes its tags off the row.
    @State private var isForumSearchOpen = false
    @State private var settings = AppSettings.shared

    /// The channel's summaries, when the toolbar shows them: the main transcript's channel,
    /// with some, and the switch on.
    private var shownSummaries: (channelID: ChannelID, summaries: [ChannelSummary], scroll: TranscriptScrollState)? {
        guard settings.showsSummaryBar, model.channelChrome.canShowSummaries,
              let scroll = model.summaryScroll, let channelID = model.selectedChannelID
        else { return nil }
        let summaries = model.summaries(in: channelID)
        return summaries.isEmpty ? nil : (channelID, summaries, scroll)
    }

    var body: some View {
        let chrome = model.channelChrome
        let primary = model.workspacePresentation.primary
        if !model.pageDrawsHeaderRow {
            HeaderBarLayout {
                leading(primary: primary).layoutValue(key: HeaderSlotKey.self, value: .leading)
                HeaderTitleCapsule()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                    .layoutValue(key: HeaderSlotKey.self, value: .center)
                trailing(chrome: chrome, primary: primary)
                    .layoutValue(key: HeaderSlotKey.self, value: .trailing)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            // A forum's row has a segmented strip on it, and they all take its height.
            .environment(\.headerControlSide, primary.isForum ? SearchField.height : ShellMetrics.headerControl)
            .padding(.leading, layout.detailHeaderLeadingClearance + Spacing.snug)
            .padding(.trailing, Spacing.snug)
            .frame(height: ShellMetrics.headerHeight)
            // The title glides to its new centre with the panel, on the panel's
            // spring, while the trailing controls — whose edge does not move —
            // stay where they are. Keyed as the panel is, never on the width.
            .animation(motion.reposition, value: ShellMotionKey(layout))
            .dragsWindow()
            .background(alignment: .top) { HeaderShade() }
        }
    }

    // MARK: Leading

    @ViewBuilder
    private func leading(primary: WorkspacePresentation.Primary) -> some View {
        HStack(spacing: Spacing.base) {
            if !layout.isSidebarShown {
                HeaderCircleButton(systemImage: "sidebar.leading", label: "Show Sidebar") {
                    ShellActions.toggleSidebar()
                }
                CreateMenu()
            }
            if case .forum(let channelID) = primary {
                ForumToolbarFilters(
                    channelID: channelID,
                    visibleTags: forumFit(channelID).visibleTags,
                    isSearching: isForumSearchOpen || !model.threadSearchText.isEmpty
                )
            }
            if let shown = shownSummaries {
                SummaryToolbarPill(channelID: shown.channelID, summaries: shown.summaries, scroll: shown.scroll)
                    .transition(.materialize(from: .leading, blurring: false))
            }
        }
        .animation(motion.panel, value: shownSummaries?.channelID)
        .transition(.materialize(from: .leading, blurring: false))
    }

    /// How a forum's row divides up, from what's been measured.
    private func forumFit(_ channelID: ChannelID) -> ForumRowFit.Answer {
        ForumRowFit.answer(
            rowWidth: rowWidth,
            titleWidth: titleWidth,
            // The sidebar's toggle and the create menu, while it's away.
            fixedLeading: layout.isSidebarShown ? 0 : SearchField.height + 56 + 2 * Spacing.base,
            toolsWidth: toolsWidth,
            tagWidths: (model.channelIndex[channelID]?.availableTags ?? []).map(ForumTagSegment.width(of:)),
            canPost: model.permissionGate.canSend(in: channelID)
        )
    }

    // MARK: Trailing

    @ViewBuilder
    private func trailing(chrome: ChannelChrome, primary: WorkspacePresentation.Primary) -> some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                if let shown = shownSummaries {
                    SummaryToolbarSteps(channelID: shown.channelID, summaries: shown.summaries, scroll: shown.scroll)
                        .transition(.materialize(from: .trailing, blurring: false))
                }
                if case .forum(let channelID) = primary, model.permissionGate.canSend(in: channelID) {
                    ForumNewPostButton(channelID: channelID, isCompact: forumFit(channelID).isNewPostCompact)
                }
                if chrome.canStartCall || chrome.canShowVoiceChat {
                    HeaderControlGroup { callControls(chrome) }
                }
                if hasChannelTools(chrome) || !primary.isServerPage {
                    HeaderControlGroup { channelTools(chrome, primary: primary) }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolsWidth = $0 }
                }
                // On a forum the circle searches its posts, and hands over to the
                // message search once that's what's been asked for.
                if case .forum(let channelID) = primary, model.messageSearch == nil {
                    ForumToolbarSearch(channelID: channelID, isOpen: $isForumSearchOpen)
                // Message search has nothing to search on Discover's pages.
                } else if !primary.isServerPage && !primary.isCall && !primary.isHomePage && primary != .discovery {
                    HeaderSearch()
                }
                // Last, at the row's very end, where Discord puts its own.
                UpdateToolbarButton()
            }
        }
    }

    private func hasChannelTools(_ chrome: ChannelChrome) -> Bool {
        chrome.canShowThreads || chrome.threadID != nil || chrome.canShowPins
            || chrome.canShowMemberList || chrome.canShowUserProfile || chrome.canShowSummaries
    }

    @ViewBuilder
    private func callControls(_ chrome: ChannelChrome) -> some View {
        if chrome.canStartCall {
            let title = chrome.isInCall ? "Leave the Call" : (chrome.isCallOngoing ? "Join the Call" : "Start a Call")
            let symbol = chrome.isInCall ? "phone.down.fill" : (chrome.isCallOngoing ? "phone.connection.fill" : "phone.fill")
            HeaderGroupButton(
                systemImage: symbol,
                label: title,
                tint: chrome.isInCall ? Palette.destructive : nil
            ) {
                toggleCall(chrome)
            }
            // **Video beside the call, in its capsule** — Discord's pair
            // (Alex, 2026-11-18). Before the call it starts one with the
            // camera on, or joins the running one with it; in the call it is
            // the camera.
            if chrome.isInCall {
                HeaderGroupButton(
                    systemImage: model.isCameraOn ? "video.slash.fill" : "video.fill",
                    label: model.isCameraOn ? "Turn Off Camera" : "Turn On Camera",
                    isActive: model.isCameraOn
                ) {
                    model.toggleCamera()
                }
            } else {
                HeaderGroupButton(
                    systemImage: "video.fill",
                    label: chrome.isCallOngoing ? "Join with Video" : "Start a Video Call"
                ) {
                    guard let channelID = model.selectedChannelID else { return }
                    model.startVideoCall(in: channelID)
                }
            }
        } else if chrome.canShowVoiceChat {
            HeaderGroupButton(
                systemImage: "bubble.left.and.text.bubble.right",
                label: chrome.isVoiceChatShown ? "Hide Chat" : "Show Chat",
                isActive: chrome.isVoiceChatShown
            ) {
                model.isVoiceChatShown.toggle()
            }
        }
    }

    @ViewBuilder
    private func channelTools(_ chrome: ChannelChrome, primary: WorkspacePresentation.Primary) -> some View {
        let isServerPage = primary.isServerPage
        if case .forum(let channelID) = primary, model.channelIndex[channelID]?.topic?.isEmpty == false {
            HeaderGroupButton(
                systemImage: "text.book.closed",
                label: "Post Guidelines",
                isActive: model.areForumGuidelinesShown
            ) {
                model.areForumGuidelinesShown.toggle()
            }
            .popover(isPresented: Binding(
                get: { model.areForumGuidelinesShown },
                set: { if !$0, model.areForumGuidelinesShown { model.areForumGuidelinesShown = false } }
            ), arrowEdge: .bottom) {
                ForumGuidelinesPopover(channelID: channelID)
            }
        }
        if chrome.canShowThreads {
            HeaderGroupButton(systemImage: "number.square", label: "Threads", isActive: chrome.areThreadsShown) {
                guard let channelID = model.selectedChannelID else { return }
                if model.openThreadsChannelID == channelID {
                    model.closeThreadBrowser()
                } else {
                    model.openThreadBrowser(channelID)
                }
            }
            .popover(isPresented: Binding(
                get: { chrome.areThreadsShown },
                set: { if !$0, chrome.areThreadsShown { model.closeThreadBrowser() } }
            ), arrowEdge: .bottom) {
                if let channelID = model.openThreadsChannelID {
                    ThreadBrowserPane(channelID: channelID)
                }
            }
        }
        if let threadID = chrome.threadID {
            ThreadMoreGroupButton(threadID: threadID)
        }
        if chrome.canShowPins {
            HeaderGroupButton(systemImage: "pin", label: "Pinned Messages", isActive: chrome.arePinsShown) {
                guard let channelID = model.selectedChannelID else { return }
                model.togglePinsPane(for: channelID)
            }
            .popover(isPresented: Binding(
                get: { chrome.arePinsShown },
                set: { if !$0, chrome.arePinsShown, let id = model.openPinsChannelID { model.togglePinsPane(for: id) } }
            ), arrowEdge: .bottom) {
                if let channelID = model.openPinsChannelID {
                    PinnedMessagesPane(channelID: channelID)
                }
            }
        }
        if chrome.canShowSummaries {
            HeaderGroupButton(
                systemImage: "scroll",
                label: chrome.areSummariesShown ? "Hide Summaries" : "Show Summaries",
                isActive: chrome.areSummariesShown
            ) {
                AppSettings.shared.showsSummaryBar.toggle()
            }
        }
        if !isServerPage {
            HeaderGroupButton(systemImage: "tray", label: "Inbox", isActive: model.isInboxShown) {
                model.toggleInbox()
            }
            .popover(isPresented: Binding(
                get: { model.isInboxShown },
                set: { if !$0, model.isInboxShown { model.toggleInbox() } }
            ), arrowEdge: .bottom) {
                InboxFlyout()
            }
        }
        if chrome.canShowMemberList {
            HeaderGroupButton(
                systemImage: "person.2",
                label: chrome.isMemberListShown ? "Hide Members" : "Show Members",
                isActive: chrome.isMemberListShown
            ) {
                model.isMemberListShown.toggle()
            }
        } else if chrome.canShowUserProfile {
            HeaderGroupButton(
                systemImage: "person.crop.circle",
                label: chrome.isUserProfileShown ? "Hide User Profile" : "Show User Profile",
                isActive: chrome.isUserProfileShown
            ) {
                model.isDirectMessageProfileShown.toggle()
            }
        }
    }

    private func toggleCall(_ chrome: ChannelChrome) {
        guard let channelID = model.selectedChannelID else { return }
        if model.connectedVoiceChannelID == channelID {
            model.leaveVoice()
        } else if chrome.isCallOngoing {
            // Already running: join it, and ring nobody.
            model.joinCall(in: channelID)
        } else {
            model.startCall(in: channelID)
        }
    }
}

// MARK: - Layout

/// Which of the toolbar row's three places a view takes.
enum HeaderSlot: Hashable {
    case leading
    case center
    case trailing
}

/// A view's place on the toolbar row.
///
/// **Named, not counted.** The layout used to need exactly three subviews and to
/// return without placing anything otherwise, and a title with nothing to say
/// contributes none. So on a page with no title, every control fell to the default
/// centre: Discover's inbox and search, mid-page (Alex's images 57 and 58).
nonisolated struct HeaderSlotKey: LayoutValueKey {
    static let defaultValue: HeaderSlot? = nil
}

/// Leading, centre, trailing: the centre slot is centred in the whole row while
/// it fits there, and slides between its neighbours when it does not — so a
/// title never sits on top of a control. A row too narrow for all three takes
/// from the leading slot first, then from the title.
struct HeaderBarLayout: Layout {
    var spacing: CGFloat = Spacing.base
    /// How tall the row is, for a bar that may grow past it. Nil is what it's given.
    var rowHeight: CGFloat?
    /// Whether the centre drops to a row of its own when one row can't hold it.
    var wrapsCenter = false
    /// The trailing slot at its widest, which that's decided with.
    ///
    /// **So nothing moves when it grows.** A search field opening in a row with just
    /// enough room would send the centre to a new row and the page down with it, as
    /// somebody started typing into it.
    var reservedTrailing: CGFloat = 0

    private func place(_ slot: HeaderSlot, in subviews: Subviews) -> LayoutSubview? {
        subviews.first { $0[HeaderSlotKey.self] == slot }
    }

    private func width(_ slot: HeaderSlot, in subviews: Subviews) -> CGFloat {
        place(slot, in: subviews)?.sizeThatFits(.unspecified).width ?? 0
    }

    private func centerWraps(in width: CGFloat, subviews: Subviews) -> Bool {
        guard wrapsCenter, place(.center, in: subviews) != nil else { return false }
        let leading = self.width(.leading, in: subviews)
        let trailing = max(self.width(.trailing, in: subviews), reservedTrailing)
        let center = self.width(.center, in: subviews)
        return leading + spacing + center + spacing + trailing > width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        guard let rowHeight else { return CGSize(width: width, height: proposal.height ?? height) }
        guard centerWraps(in: width, subviews: subviews),
              let center = place(.center, in: subviews)
        else { return CGSize(width: width, height: rowHeight) }
        return CGSize(
            width: width,
            height: rowHeight + center.sizeThatFits(.unspecified).height + Spacing.base
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let midY = bounds.minY + (rowHeight ?? bounds.height) / 2
        let wraps = centerWraps(in: bounds.width, subviews: subviews)
        let trailing = place(.trailing, in: subviews)?.sizeThatFits(.unspecified) ?? .zero
        let leading = leadingSize(in: bounds.width, trailing: trailing.width, wraps: wraps, subviews: subviews)
        place(.leading, in: subviews)?.place(
            at: CGPoint(x: bounds.minX, y: midY),
            anchor: .leading,
            proposal: ProposedViewSize(leading)
        )
        place(.trailing, in: subviews)?.place(
            at: CGPoint(x: bounds.maxX, y: midY),
            anchor: .trailing,
            proposal: ProposedViewSize(trailing)
        )
        guard let center = place(.center, in: subviews) else { return }
        if wraps, let rowHeight {
            let size = center.sizeThatFits(.unspecified)
            center.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY + rowHeight + size.height / 2),
                anchor: .center,
                proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
            )
            return
        }
        let lower = bounds.minX + leading.width + (leading.width > 0 ? spacing : 0)
        let upper = bounds.maxX - trailing.width - (trailing.width > 0 ? spacing : 0)
        let available = max(0, upper - lower)
        let ideal = center.sizeThatFits(ProposedViewSize(width: available, height: rowHeight ?? bounds.height))
        let width = min(ideal.width, available)
        let x = min(max(bounds.midX - width / 2, lower), upper - width)
        center.place(
            at: CGPoint(x: x, y: midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: width, height: ideal.height)
        )
    }

    /// The leading slot's size: its own, unless the row can't hold it beside the
    /// title and the trailing slot.
    ///
    /// **The leading slot gives way before the title does.** A summary's pill can cut
    /// its title short and then drop it (`SummaryToolbarPill`), and only once it can
    /// give no more does the title truncate (`HuggingWidth`). The sidebar's controls
    /// and a forum's filters are fixed, so they never shrink.
    private func leadingSize(in width: CGFloat, trailing: CGFloat, wraps: Bool, subviews: Subviews) -> CGSize {
        guard let leading = place(.leading, in: subviews) else { return .zero }
        let ideal = leading.sizeThatFits(.unspecified)
        guard !wraps, ideal.width > 0, let center = place(.center, in: subviews) else { return ideal }
        let title = center.sizeThatFits(.unspecified).width
        guard title > 0 else { return ideal }
        let room = width - title - spacing - (trailing > 0 ? trailing + spacing : 0)
        guard room < ideal.width else { return ideal }
        let least = leading.sizeThatFits(ProposedViewSize(width: 0, height: ideal.height)).width
        return CGSize(width: max(least, room), height: ideal.height)
    }
}

/// Gives its one view the width it wants, and less when there's less.
///
/// **What the title capsule hugs its label with, where it had `.fixedSize()`.** A
/// `Menu` stretches to whatever it's offered, so it was fixed at its own size, and a
/// row too narrow for it put the title under the trailing controls. This hugs the same
/// way and still gives way: the label's lines truncate.
struct HuggingWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(.unspecified)
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - The title

/// Who or what the column shows, in a glass capsule centred over it — the way
/// Messages heads a conversation with its contact. The channel's acts hang off
/// it as a menu.
struct HeaderTitleCapsule: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @Environment(\.headerControlSide) private var rowSide

    private var title: HeaderTitle { model.headerTitle }
    private var chrome: ChannelChrome { model.channelChrome }

    var body: some View {
        if !title.isEmpty {
            HuggingWidth {
                Menu {
                    ChannelTitleMenu(chrome: chrome, model: model)
                } label: {
                    label
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .frame(height: rowSide)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .animation(motion.glassMorph, value: title.name)
            .help(title.subtitle.isEmpty ? title.name : "\(title.name) — \(title.subtitle)")
            .accessibilityLabel(Text(title.name))
        }
    }

    private var label: some View {
        HStack(spacing: Spacing.base) {
            face
            VStack(alignment: .leading, spacing: 0) {
                Text(title.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .lineLimit(1)
                if !title.subtitle.isEmpty {
                    Text(title.subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(.leading, title.symbolName == nil ? 6 : 12)
        .padding(.trailing, 14)
        // The whole capsule opens the menu, its padding too: a plain button answers
        // only where its label draws.
        .frame(height: rowSide)
        .contentShape(.capsule)
    }

    @ViewBuilder
    private var face: some View {
        if let symbolName = title.symbolName {
            Image(symbol: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.secondary)
        } else {
            AvatarView(
                url: title.avatarURL,
                monogram: title.monogram ?? "?",
                side: ShellMetrics.titleAvatar
            )
            .overlay(alignment: .bottomTrailing) {
                if let status = title.status {
                    PresenceDot(status: status, side: 8).offset(x: 1, y: 1)
                }
            }
        }
    }
}

// MARK: - Shade

/// The soft band behind the header, so its glass reads against a quiet field
/// rather than whatever the wallpaper or the transcript has under it —
/// Noodle's header shade, drawn behind the controls and in front of the ground.
///
/// **Drawn under the sidebar column as well** (`WindowShell`): the toolbar runs
/// the window's whole width, and with the shade on the detail column alone the
/// strip above the floating panel showed the ground undarkened — a bright
/// line along the sidebar's top that stopped at the panel's corner (Alex,
/// 2026-11-18, his Images 147–149).
struct HeaderShade: View {
    /// How far down it reaches: the toolbar's row by default; a side
    /// column's header passes its own (`ColumnTranscript`).
    var height: CGFloat = ShellMetrics.headerHeight + 18

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.06), location: 0),
                .init(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.03), location: 0.55),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - A page's own row

extension AppModel {
    /// Whether the page in the column draws the toolbar row itself, with its own
    /// controls on it. See `PageHeaderBar`.
    var pageDrawsHeaderRow: Bool {
        switch workspacePresentation.primary {
        case .discovery:
            // An app's page, opened from Discover, has a bar of its own under the
            // ordinary row.
            discovery?.openAppID == nil && discovery?.openStoreID == nil
        case .guildSurface(_, .channelsAndRoles), .guildSurface(_, .browseChannels):
            channelsAndRolesPresentation != nil
        case .guildSurface(_, .serverHub):
            // The hub's row carries its Edit and Settings, and in an edit Add
            // Widget, Cancel and Save — `ServerHubBar`.
            serverHubPresentation != nil
        case .guildSurface(_, .members):
            // The Members page, once its store is this server's: search, Sort
            // and Prune are on the row. While it loads, the ordinary row.
            memberSafety?.guildID == selectedGuildID && memberSafety != nil
        default:
            false
        }
    }
}
