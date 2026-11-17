import SwiftUI

/// A leaderboard, as Discord's widget lays it out (`tI`): the podium on the
/// competition's last day, then every place in the top twenty, in a list that
/// scrolls inside the card — 320 points tall on the page, 560 in the full view
/// (`.list_yz6RlA`) — and when the standings were last worked out.
///
/// **The reader is never lost in it**: their own row floats at the list's top
/// or foot while it is scrolled out of sight, and a click on it scrolls back
/// to it (Discord's "Jump to you"). A reader not on the board at all gets the
/// bar that says how to get on it, over the list's foot.
struct LeaderboardCardView: View {
    var board: LeaderboardCardModel
    /// The full view (`LeaderboardPanel`), which lets the list run taller.
    var isExpanded = false

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var width: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// The reader's row, in the list's visible space.
    @State private var readerFrame: CGRect?
    @State private var unrankedHeight: CGFloat = 0

    private var maxListHeight: CGFloat { isExpanded ? 560 : 320 }
    /// Discord's container rule: games only on a card 450 points wide or more.
    private var showsGames: Bool { width >= 450 }
    private var readerRow: LeaderboardCardModel.Row? { board.rows.first(where: \.isReader) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    list
                }
                .scrollIndicators(.automatic)
                .frame(height: contentHeight > 0 ? min(contentHeight, maxListHeight) : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .overlay(alignment: floatingEdge == .top ? .top : .bottom) {
                    if let reader = readerRow, let edge = floatingEdge {
                        jumpToYou(reader, edge: edge, proxy: proxy)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let unranked = board.unranked {
                        LeaderboardUnrankedRow(unranked: unranked)
                            .padding(.horizontal, Spacing.base)
                            .padding(.bottom, Spacing.base)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { unrankedHeight = $0 }
                    }
                }
                .animation(motion.standard, value: floatingEdge)
            }
            LeaderboardFooter(lastUpdated: board.lastUpdated)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var list: some View {
        VStack(spacing: 2) {
            if !board.podium.isEmpty {
                LeaderboardPodium(rows: board.podium, open: open)
            }
            ForEach(board.rows) { row in
                Button {
                    open(row)
                } label: {
                    LeaderboardRowView(row: row, showsGames: showsGames)
                }
                .buttonStyle(.plain)
                .disabled(row.isHidden)
                .accessibilityHint(Text("Opens their profile"))
                .id(row.id)
                // Only the reader's row reports where it is; everyone else's
                // stays nil and never calls back.
                .onGeometryChange(for: CGRect?.self) { proxy in
                    row.isReader ? proxy.frame(in: .scrollView) : nil
                } action: { frame in
                    readerFrame = frame
                }
            }
        }
        .padding(Spacing.base)
        // Room for the bar over the foot, so the last place can scroll above it.
        .padding(.bottom, board.unranked == nil ? 0 : unrankedHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }

    /// Where the reader's row floats: the edge it went past, while it isn't
    /// wholly in view.
    private var floatingEdge: VerticalEdge? {
        guard let frame = readerFrame, viewportHeight > 0 else { return nil }
        if frame.minY < 0 { return .top }
        if frame.maxY > viewportHeight { return .bottom }
        return nil
    }

    private func jumpToYou(_ reader: LeaderboardCardModel.Row, edge: VerticalEdge, proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(motion.reposition) { proxy.scrollTo(reader.id, anchor: .center) }
        } label: {
            LeaderboardRowView(row: reader, showsGames: showsGames)
                // Opaque, so the rows it floats over never read through it.
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.row))
                .shadow(color: .black.opacity(0.25), radius: 8, y: edge == .top ? 2 : -2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.base)
        .padding(edge == .top ? .top : .bottom, Spacing.base)
        .transition(.move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
        .help("Jump to you")
        .accessibilityLabel(Text("Jump to you"))
    }

    /// A place opens the person's profile on its Activity tab, as Discord's
    /// row does (`openUserProfileModal`, RECENT_ACTIVITY), over whatever
    /// raised it.
    private func open(_ row: LeaderboardCardModel.Row) {
        model.openProfile(row.id, anchor: .zero, depth: .full, tab: .activity)
    }
}
