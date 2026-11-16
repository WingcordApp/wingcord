import AppKit
import SwiftUI
import WingcordCore

// MARK: - More Active Posts
//
// Discord's popout on a channel row (`sk`, read 2026-11-16): resting on a forum
// or a channel with threads for 200 ms opens a list of its active posts or
// threads the channel list does not already show, newest message first — five
// for a forum, three for a channel — each with its starter's face, its title
// and how long ago it moved, and See All under them. It goes 250 ms after the
// pointer leaves both the row and the popout.

/// One post or thread in the flyout.
struct ActivePostRow: Identifiable, Hashable, Sendable {
    var id: ChannelID
    var title: String
    var avatarURL: URL?
    var monogram: String
    var lastActive: Date
}

extension AppModel {

    /// The channel's active posts or threads the channel list does not already
    /// show, newest message first.
    ///
    /// **Followed ones are left out**: the list draws them under the channel
    /// already (`appendThreadRows`), which is Discord's own rule — it drops its
    /// "relevant joined" threads from the popout.
    func activePosts(in channelID: ChannelID, limit: Int) -> [ActivePostRow] {
        var posts: [(Channel, Date)] = []
        for threadID in channelIndex.threadIDs(inParent: channelID) {
            guard threadMemberships[threadID] == nil,
                  let thread = channelIndex[threadID],
                  thread.threadMetadata?.isArchived != true,
                  permissionGate.canView(threadID)
            else { continue }
            posts.append((thread, (thread.lastMessageID ?? MessageID(rawValue: thread.id.rawValue)).timestamp))
        }
        posts.sort { $0.1 > $1.1 }
        return posts.prefix(limit).map { thread, lastActive in
            let owner = thread.ownerID.flatMap { users[$0] }
            return ActivePostRow(
                id: thread.id,
                title: thread.name,
                avatarURL: owner.flatMap { avatarURL(for: $0, side: 16) },
                monogram: owner?.monogram ?? "?",
                lastActive: lastActive
            )
        }
    }

    /// Whether a text channel has active threads the list does not show.
    func hasUnlistedActiveThreads(in channelID: ChannelID) -> Bool {
        channelIndex.threadIDs(inParent: channelID).contains { threadID in
            threadMemberships[threadID] == nil
                && channelIndex[threadID]?.threadMetadata?.isArchived != true
        }
    }

    /// Asks for a forum's posts when the flyout finds none yet — the board's
    /// own first page, which fills the index the flyout reads.
    func preloadActivePosts(in channelID: ChannelID) {
        guard channelIndex[channelID]?.isForumLike == true, forumBoards[channelID] == nil else { return }
        loadThreadListForFlyout(channelID)
    }
}

/// The one flyout, shown beside whichever row the pointer rests on.
///
/// **An `NSPopover` held here, not a popover on each row** — INVARIANTS §2:
/// a presentation modifier on a row is paid for by every row. The list's
/// hover router hands over the row's own view as it is hovered, and the
/// popover anchors to it. The system popover carries Liquid Glass by itself;
/// the content adds nothing but its rows.
@MainActor
final class ActivePostsFlyout {
    static let shared = ActivePostsFlyout()

    /// The store, handed over by the channel list as it appears
    /// (`ChannelSidebarContainer`).
    weak var model: AppModel?

    private var popover: NSPopover?
    private var channelID: ChannelID?
    private var isOverRow = false
    private var isOverFlyout = false
    private var enterTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?

    /// Discord's 200 ms in; out a little later than its 250, because this
    /// popover stands an arrow's length off the row where Discord's touches it,
    /// and the pointer has that gap to cross on its way in.
    private static let dwell: Duration = .milliseconds(200)
    private static let grace: Duration = .milliseconds(350)

    func pointerEnteredRow(_ channelID: ChannelID, anchor: NSView) {
        isOverRow = true
        exitTask?.cancel()
        if self.channelID == channelID, popover?.isShown == true { return }
        enterTask?.cancel()
        // Another row's flyout goes at once: one popover at a time (HIG).
        if self.channelID != channelID { close() }
        self.channelID = channelID
        model?.preloadActivePosts(in: channelID)
        enterTask = Task { [weak self, weak anchor] in
            try? await Task.sleep(for: Self.dwell)
            // A forum whose posts are on their way gets a moment more.
            for _ in 0..<10 {
                guard let self, !Task.isCancelled, self.isOverRow else { return }
                if !self.rows(for: channelID).isEmpty { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self, !Task.isCancelled, self.isOverRow, let anchor, anchor.window != nil else { return }
            self.show(channelID, beside: anchor)
        }
    }

    func pointerLeftRow(_ channelID: ChannelID) {
        guard self.channelID == channelID else { return }
        isOverRow = false
        enterTask?.cancel()
        scheduleExit()
    }

    fileprivate func pointerOverFlyout(_ isOver: Bool) {
        isOverFlyout = isOver
        if isOver {
            exitTask?.cancel()
        } else {
            scheduleExit()
        }
    }

    private func scheduleExit() {
        exitTask?.cancel()
        exitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard let self, !Task.isCancelled, !self.isOverRow, !self.isOverFlyout else { return }
            self.close()
        }
    }

    func close() {
        enterTask?.cancel()
        exitTask?.cancel()
        popover?.close()
        popover = nil
        isOverFlyout = false
    }

    private func rows(for channelID: ChannelID) -> [ActivePostRow] {
        guard let model else { return [] }
        let isForum = model.channelIndex[channelID]?.isForumLike == true
        return model.activePosts(in: channelID, limit: isForum ? 5 : 3)
    }

    private func show(_ channelID: ChannelID, beside anchor: NSView) {
        guard let model, let channel = model.channelIndex[channelID] else { return }
        let rows = rows(for: channelID)
        guard !rows.isEmpty else { return }
        let content = ActivePostsFlyoutView(
            title: channel.isForumLike ? "More Active Posts" : "More Active Threads",
            seeAllSymbol: channel.isForumLike ? "bubble.left.and.text.bubble.right" : "number",
            rows: rows,
            open: { [weak self] postID in
                self?.close()
                self?.model?.openThread(postID, as: .fullView)
            },
            seeAll: { [weak self] in
                self?.close()
                if channel.isForumLike {
                    self?.model?.selectChannel(channelID)
                } else {
                    self?.model?.openThreadBrowser(channelID)
                }
            }
        )
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = FlyoutHostController(rootView: content) { [weak self] isOver in
            self?.pointerOverFlyout(isOver)
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        self.popover = popover
    }
}

/// The popover's content, with a pointer tracker of its own.
///
/// **`.activeAlways`, which SwiftUI's `onHover` is not.** The popover's window
/// never becomes key — the pointer resting on a row must not take the
/// keyboard — and a tracking area that waits for a key window reports
/// nothing: the pointer crossing into the flyout went unseen, and it closed
/// under the hand on the way to a post.
private final class FlyoutHostController<Content: View>: NSHostingController<Content> {
    private let onPointer: (Bool) -> Void
    private var area: NSTrackingArea?

    init(rootView: Content, onPointer: @escaping (Bool) -> Void) {
        self.onPointer = onPointer
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard area == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onPointer(true) }
    override func mouseExited(with event: NSEvent) { onPointer(false) }
}

/// The flyout's rows. A value view: the controller hands it everything.
struct ActivePostsFlyoutView: View {
    var title: String
    var seeAllSymbol: String
    var rows: [ActivePostRow]
    var open: (ChannelID) -> Void
    var seeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, Spacing.base)
                .padding(.top, Spacing.tight)
                .padding(.bottom, Spacing.hair)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                ActivePostFlyoutRow(row: row, action: { open(row.id) })
            }
            ActivePostFlyoutRow.seeAll(symbol: seeAllSymbol, action: seeAll)
        }
        .padding(Spacing.tight + Spacing.hair)
        .frame(width: 380, alignment: .leading)
    }
}

private struct ActivePostFlyoutRow: View {
    var row: ActivePostRow?
    var symbol: String?
    var label: String?
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    init(row: ActivePostRow, action: @escaping () -> Void) {
        self.row = row
        self.action = action
    }

    private init(symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    static func seeAll(symbol: String, action: @escaping () -> Void) -> ActivePostFlyoutRow {
        ActivePostFlyoutRow(symbol: symbol, label: "See All", action: action)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                if let row {
                    AvatarView(url: row.avatarURL, monogram: row.monogram, side: 16)
                    Text(row.title)
                        .font(.system(.body))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\u{2022}")
                        .foregroundStyle(Ink.tertiary)
                    Text(Self.ago(row.lastActive))
                        .font(.system(.callout))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize()
                } else if let symbol, let label {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 16)
                    Text(label)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Ink.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 30)
            .background {
                // The popover's own corner, concentric — FlyoutMenu's rule.
                ConcentricRectangle()
                    .fill(isHovered ? Ink.primary.opacity(0.1) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovered != hovering else { return }
            isHovered = hovering
        }
        .animation(motion.hover, value: isHovered)
    }

    /// "23h ago", "1d ago" — Discord's popout's own short form.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
