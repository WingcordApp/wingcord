import SwiftUI
import WingcordCore

/// A thread's own menu — Discord's `thread-context`, from a right-click, the
/// split view's ⋯, or the toolbar's ⋯ over a thread open as the page.
///
/// **Three places, one list of rows.** Which rows each place holds, and in
/// what order, is the model's — `ThreadMenu.groups(at:developerMode:)` — so
/// this view only draws them; a row it is handed is a row the reader may use.
///
/// **Discord's words, which change with what the thread is**: Follow Post and
/// Join Thread, Close Post and Close Thread, and Discord's own "Unlock post".
/// Mute, Notification Settings and Edit Tags open in place, as the channel
/// menu's levels do.
struct ThreadOptionsMenu: View {
    var threadID: ChannelID
    var place: ThreadMenuPlace
    var close: () -> Void

    enum Surface: Hashable {
        case root
        case mute
        case notifications
        case tags
    }

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var surface = Surface.root

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let menu = model.threadMenu(for: threadID) {
                switch surface {
                case .root: root(menu)
                case .mute: mutePicker(menu)
                case .notifications: levels(menu)
                case .tags: tags(menu)
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: ChannelOptionsMenu.width)
        .animation(motion.standard, value: surface)
    }

    // MARK: Root

    @ViewBuilder
    private func root(_ menu: ThreadMenu) -> some View {
        let groups = menu.groups(at: place, developerMode: AppSettings.shared.developerMode)
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { FlyoutDivider() }
            ForEach(groups[index], id: \.self) { item in
                row(item, menu)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ThreadMenu.Item, _ menu: ThreadMenu) -> some View {
        switch item {
        case .markRead:
            FlyoutRow(title: "Mark As Read", symbolName: "checkmark.circle", isEnabled: menu.hasUnread) {
                model.markRead(threadID)
                close()
            }
        case .follow:
            FlyoutRow(
                title: menu.isJoined
                    ? (menu.isPost ? "Unfollow Post" : "Leave Thread")
                    : (menu.isPost ? "Follow Post" : "Join Thread"),
                symbolName: menu.isJoined ? "minus.circle" : "plus.circle"
            ) {
                model.setThreadFollowed(!menu.isJoined, threadID: threadID, location: place.followLocation)
                close()
            }
        case .openFullView:
            FlyoutRow(title: "Open in Full View", symbolName: "arrow.up.left.and.arrow.down.right") {
                close()
                model.openThread(threadID, as: .fullView)
            }
        case .openSplitView:
            FlyoutRow(title: "Open in Split View", symbolName: "rectangle.split.2x1") {
                close()
                model.openThread(threadID, as: .splitView)
            }
        case .jumpToTop:
            FlyoutRow(title: "Jump To Top", symbolName: "arrow.up.to.line") {
                close()
                model.jumpToThreadTop(threadID)
            }
        case .closeOrOpen:
            FlyoutRow(
                title: menu.isArchived
                    ? (menu.isPost ? "Open Post" : "Open Thread")
                    : (menu.isPost ? "Close Post" : "Close Thread"),
                symbolName: menu.isArchived ? "tray.and.arrow.up" : "archivebox"
            ) {
                close()
                model.setThreadArchived(!menu.isArchived, threadID: threadID)
            }
        case .lock:
            FlyoutRow(
                // "Unlock post" is Discord's own capitalisation (`/OKSxp`).
                title: menu.isLocked
                    ? (menu.isPost ? "Unlock post" : "Unlock Thread")
                    : (menu.isPost ? "Lock Post" : "Lock Thread"),
                symbolName: menu.isLocked ? "lock.open" : "lock"
            ) {
                close()
                model.setThreadLocked(!menu.isLocked, threadID: threadID)
            }
        case .edit:
            FlyoutRow(title: menu.isPost ? "Edit Post" : "Edit Thread", symbolName: "pencil") {
                close()
                model.editThread(threadID)
            }
        case .editTags:
            FlyoutRow(title: "Edit Tags", symbolName: "tag", accessory: .disclosure) {
                surface = .tags
            }
        case .copyLink:
            FlyoutRow(title: "Copy Link", symbolName: "link") {
                AppModel.copy(menu.link)
                close()
            }
        case .mute:
            muteRow(menu)
        case .notifications:
            FlyoutRow(
                title: "Notification Settings",
                symbolName: "bell.badge",
                accessory: .disclosure,
                isEnabled: menu.isJoined
            ) {
                surface = .notifications
            }
        case .invitable:
            FlyoutRow(
                title: "Anyone can invite",
                symbolName: "person.badge.plus",
                accessory: .checkbox(menu.isInvitable)
            ) {
                model.setThreadInvitable(!menu.isInvitable, threadID: threadID)
            }
        case .pin:
            FlyoutRow(
                title: menu.isPinned ? "Unpin Post" : "Pin Post",
                symbolName: menu.isPinned ? "pin.slash" : "pin"
            ) {
                close()
                model.setPostPinned(!menu.isPinned, postID: threadID)
            }
        case .delete:
            if let deletion = menu.gate.deletion {
                FlyoutRow(title: deletion.title, symbolName: "trash", isDestructive: true) {
                    close()
                    model.requestThreadDeletion(threadID)
                }
            }
        case .search:
            FlyoutRow(title: "Search", symbolName: "magnifyingglass") {
                close()
                model.searchFromThread(threadID)
            }
        case .pins:
            FlyoutRow(title: "Pins", symbolName: "pin") {
                close()
                model.showThreadPins(threadID)
            }
        case .copyThreadID:
            FlyoutRow(title: "Copy Thread ID", symbolName: "number") {
                AppModel.copy(threadID.description)
                close()
            }
        }
    }

    /// Unmute while muted, with Discord's "Muted until …" under it; otherwise
    /// the durations. Greyed out until the reader is in the thread — a mute
    /// lives on a membership, as Discord's does.
    @ViewBuilder
    private func muteRow(_ menu: ThreadMenu) -> some View {
        if menu.isMuted {
            FlyoutRow(
                title: menu.isPost ? "Unmute Post" : "Unmute Thread",
                subtitle: menu.muteEnd,
                symbolName: "bell"
            ) {
                model.setThreadMute(nil, threadID: threadID)
                close()
            }
        } else {
            FlyoutRow(
                title: menu.isPost ? "Mute Post" : "Mute Thread",
                symbolName: "bell.slash",
                accessory: .disclosure,
                isEnabled: menu.isJoined
            ) {
                surface = .mute
            }
        }
    }

    // MARK: Levels

    @ViewBuilder
    private func mutePicker(_ menu: ThreadMenu) -> some View {
        FlyoutBackRow(title: menu.isPost ? "Mute Post" : "Mute Thread") { surface = .root }
        FlyoutDivider()
        ForEach(MuteDuration.allCases, id: \.self) { duration in
            FlyoutRow(title: duration.title, symbolName: "clock") {
                model.setThreadMute(duration, threadID: threadID)
                close()
            }
        }
    }

    @ViewBuilder
    private func levels(_ menu: ThreadMenu) -> some View {
        FlyoutBackRow(title: "Notification Settings") { surface = .root }
        FlyoutDivider()
        ForEach(ThreadNotification.allCases, id: \.self) { setting in
            FlyoutRow(
                title: Self.title(for: setting),
                accessory: .tick(menu.notification == setting),
                isSelected: menu.notification == setting
            ) {
                model.setThreadNotification(setting, threadID: threadID)
            }
        }
    }

    /// Discord's Edit Tags (`565846`): every tag the reader may use, ticked
    /// where the post carries it, and the rest greyed out once it carries five.
    @ViewBuilder
    private func tags(_ menu: ThreadMenu) -> some View {
        FlyoutBackRow(title: "Edit Tags") { surface = .root }
        FlyoutDivider()
        ScrollView {
            VStack(spacing: 0) {
                ForEach(menu.gate.usableTags) { tag in
                    let isOn = menu.appliedTagIDs.contains(tag.id)
                    FlyoutRow(
                        title: tag.name,
                        emoji: tag.emoji,
                        accessory: .checkbox(isOn),
                        isEnabled: isOn || menu.appliedTagIDs.count < ThreadMenu.tagLimit
                    ) {
                        model.togglePostTag(tag.id, postID: threadID)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: FlyoutMetrics.listHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func title(for setting: ThreadNotification) -> String {
        switch setting {
        case .allMessages: "All Messages"
        case .onlyMentions: "Only @mentions"
        case .nothing: "Nothing"
        }
    }
}

// MARK: - The ⋯ over a thread

/// The ⋯ that raises a thread's menu from the split view's header or the
/// toolbar — Discord's "More", in each place's own control.
///
/// **The popover hangs off the control itself**, which is the one case §2
/// leaves alone: a single control evaluated once, not a row in a list.
struct ThreadMoreButton<Glyph: View>: View {
    var threadID: ChannelID
    var place: ThreadMenuPlace
    /// The control as its place draws it — a glass circle in the column's
    /// header, a toolbar item's label in the toolbar.
    @ViewBuilder var label: Glyph

    @Environment(AppModel.self) private var model
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: { label }
            .help("More")
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                ThreadOptionsMenu(threadID: threadID, place: place, close: { isShown = false })
                    .environment(model)
                    .presentationBackground(.clear)
            }
    }
}

// MARK: - Presenting

/// The right-click menu, hung off the row's rect, and what any of the three
/// menus can raise: Discord's delete confirmation, "Pin this post?", and the
/// edit sheet.
struct ThreadOptionsPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content
            .popover(
                item: $model.threadOptionsMenu,
                attachmentAnchor: .rect(.rect(model.threadOptionsMenu?.anchor ?? .zero)),
                arrowEdge: .trailing
            ) { request in
                ThreadOptionsMenu(
                    threadID: request.threadID,
                    place: .list,
                    close: { model.threadOptionsMenu = nil }
                )
                .environment(model)
                .presentationBackground(.clear)
            }
            .alert(
                model.threadDeletion?.deletion.title ?? "",
                isPresented: Binding(
                    get: { model.threadDeletion != nil },
                    set: { if !$0 { model.threadDeletion = nil } }
                ),
                presenting: model.threadDeletion
            ) { request in
                Button(request.deletion.title, role: .destructive) { model.confirmThreadDeletion() }
                Button("Cancel", role: .cancel) { model.threadDeletion = nil }
            } message: { request in
                Text(request.deletion.message(name: request.name))
            }
            // Discord's has "Okay" alone and is dismissed by closing it. An
            // alert here has no close box, so its way out is a Cancel button —
            // Discord's word for it everywhere else.
            .alert(
                "Pin this post?",
                isPresented: Binding(
                    get: { model.pinReplacement != nil },
                    set: { if !$0 { model.pinReplacement = nil } }
                ),
                presenting: model.pinReplacement
            ) { _ in
                Button("Okay") { model.confirmPinReplacement() }
                Button("Cancel", role: .cancel) { model.pinReplacement = nil }
            } message: { _ in
                Text("There\u{2019}s a post that\u{2019}s pinned already. Pinning this post will remove the existing pinned post.")
            }
            .sheet(item: $model.threadEditor) { request in
                ThreadEditSheet(request: request)
                    .environment(model)
            }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsThreadOptions() -> some View {
        modifier(ThreadOptionsPresenter())
    }
}
