import AppKit
import SwiftUI
import WingcordCore

// MARK: - Where a drop on the rail lands

/// What a drop on the rail does — the two acts Discord's drop targets
/// dispatch (`tH` → `moveById(source, target, below, combine)`).
enum RailDrop: Hashable, Sendable {
    /// Put `source` beside the target: above it, or below it.
    case move(RailNodeID, nextTo: RailNodeID, below: Bool)
    /// Drop a server ON a top-level entry: into the folder it is, or into a
    /// new folder made of the two.
    case combine(GuildID, with: RailNodeID)
}

/// One tile the pointer can be over, in the order the rail draws them.
struct RailDropTile: Equatable {
    var node: RailNodeID
    /// In the rail's content space — `GuildRail.contentSpace`.
    var frame: CGRect
    /// The open folder it sits in, for a server inside one.
    var folder: UInt64? = nil
    /// Whether it is the last server of an open folder, whose foot is where
    /// that folder ends.
    var closesFolder = false
}

/// Where a drop would land, and what the rail draws while it would.
struct RailDropTarget: Equatable {
    var drop: RailDrop
    var mark: Mark

    enum Mark: Equatable {
        /// A line across the rail at this height, where the entry would go.
        case line(y: CGFloat)
        /// The tile the entry would go into.
        case ring(RailNodeID)
    }
}

/// Discord's drop zones, as geometry.
///
/// **Measured off its stylesheet** (`759223`), on its 48-point tile with an
/// 8-point gap: each top-level tile carries a zone from 16 points above it to
/// 4 below, split in half — the top half a line that puts the entry above the
/// tile, the bottom half a target that puts it *into* the tile — and the next
/// tile's zone lies over the foot of this one's. Worked through, that is:
///
///  - the gap above a tile and its top **three-eighths**: above it;
///  - from there to **five-sixths** down, for a top-level tile: into it;
///  - the rest of it, and the gap below: the next tile's "above".
///
/// Kept as proportions of the tile rather than points, so they hold at this
/// rail's own tile size. A server inside an open folder takes nothing into
/// it — its whole height is "above" — and the foot of an open folder's last
/// server is the end of that folder (Discord's `tK`). Past the last tile is
/// below the last top-level entry, the target Discord hangs under its Add a
/// Server button.
enum RailDropTargeting {
    static let combineTop: CGFloat = 18 / 48
    static let combineBottom: CGFloat = 40 / 48

    static func target(
        at y: CGFloat,
        dragging source: RailNodeID,
        tiles: [RailDropTile],
        folders: [GuildFolder],
        gap: CGFloat
    ) -> RailDropTarget? {
        for (index, tile) in tiles.enumerated() {
            let top = tile.frame.minY
            let height = tile.frame.height
            if y < top + height * combineBottom {
                if tile.folder == nil, y >= top + height * combineTop,
                   case .guild(let guildID) = source,
                   GuildArrangement.canCombine(source, with: tile.node, in: folders)
                {
                    return RailDropTarget(drop: .combine(guildID, with: tile.node), mark: .ring(tile.node))
                }
                guard GuildArrangement.canMove(source, nextTo: tile.node, in: folders) else { return nil }
                let above = index > 0 ? tiles[index - 1].frame.maxY : top - gap
                return RailDropTarget(
                    drop: .move(source, nextTo: tile.node, below: false),
                    mark: .line(y: (above + top) / 2)
                )
            }
            if tile.closesFolder, let folderID = tile.folder, y < tile.frame.maxY + gap {
                guard case .guild(let guildID) = source,
                      GuildArrangement.canCombine(source, with: .folder(folderID), in: folders)
                else { return nil }
                return RailDropTarget(
                    drop: .combine(guildID, with: .folder(folderID)),
                    mark: .line(y: tile.frame.maxY + gap / 2)
                )
            }
        }
        guard let last = folders.last else { return nil }
        let node: RailNodeID = last.id.map(RailNodeID.folder) ?? .guild(last.guildIDs[0])
        guard GuildArrangement.canMove(source, nextTo: node, in: folders) else { return nil }
        return RailDropTarget(
            drop: .move(source, nextTo: node, below: true),
            mark: .line(y: (tiles.last?.frame.maxY ?? 0) + gap / 2)
        )
    }
}

// MARK: - The drag in flight

/// A tile being carried down the rail.
///
/// **Driven by a gesture inside the rail, not by the system's drag session.**
/// The rail has to know where a drop would land at every point of the carry —
/// Discord's line and its target — and that the carry ended even when it ended
/// outside the window; a system drag reports neither to its source. It also
/// has to scroll a rail of ninety-seven servers while the pointer rests at its
/// edge, which a drag session does not do for a `ScrollView`.
///
/// **What is drawn from it is observed; what is not, is not.** The tiles'
/// frames are written as the rail lays out and read only when the pointer
/// moves, so they invalidate nothing.
@MainActor
@Observable
final class RailDrag {
    /// What is being carried, or nil.
    private(set) var source: RailNodeID?
    /// Where the pointer is, in the rail's content space.
    private(set) var location: CGPoint = .zero
    /// Where a drop would land now.
    private(set) var target: RailDropTarget?

    @ObservationIgnored var frames: [RailNodeID: CGRect] = [:]
    /// The rail's items, for the order the tiles are in and what may go where.
    @ObservationIgnored var items: [RailItem] = []
    @ObservationIgnored var drop: (RailDrop) -> Void = { _ in }
    /// The scroll view the rail is inside, so the carry can scroll it.
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored private var autoscroll: Task<Void, Never>?

    /// The gap between tiles — the rail's own stack spacing.
    static let gap = Spacing.base
    /// How close to the rail's top or foot the pointer has to be before it
    /// scrolls, and how fast it goes at the very edge, in points a frame.
    private static let edge: CGFloat = 44
    private static let speed: CGFloat = 10

    var isActive: Bool { source != nil }

    /// Whether the combine target is this tile — which is when its name shows,
    /// as Discord names the server a drop would go into.
    func isCombineTarget(_ node: RailNodeID) -> Bool {
        if case .ring(let ringed) = target?.mark { return ringed == node }
        return false
    }

    func changed(_ node: RailNodeID, at point: CGPoint) {
        if source == nil { source = node }
        guard source == node else { return }
        location = point
        retarget()
        updateAutoscroll()
    }

    /// The carry is over: dropped where it is, or — with no point — given up.
    func ended(at point: CGPoint?) {
        guard source != nil else { return }
        if point != nil, let target { drop(target.drop) }
        autoscroll?.cancel()
        autoscroll = nil
        source = nil
        target = nil
    }

    private func retarget() {
        guard let source else { return }
        let next = RailDropTargeting.target(
            at: location.y,
            dragging: source,
            tiles: tiles,
            folders: arrangement,
            gap: Self.gap
        )
        if target != next { target = next }
    }

    /// The tiles, in drawing order, with the frames they were last laid out at.
    private var tiles: [RailDropTile] {
        var tiles: [RailDropTile] = []
        for item in items {
            switch item {
            case .guild(let guild):
                if let frame = frames[.guild(guild.id)] {
                    tiles.append(RailDropTile(node: .guild(guild.id), frame: frame))
                }
            case .folder(let folder):
                if let frame = frames[.folder(folder.id)] {
                    tiles.append(RailDropTile(node: .folder(folder.id), frame: frame))
                }
                guard folder.isExpanded else { continue }
                for (index, guild) in folder.guilds.enumerated() {
                    guard let frame = frames[.guild(guild.id)] else { continue }
                    tiles.append(RailDropTile(
                        node: .guild(guild.id),
                        frame: frame,
                        folder: folder.id,
                        closesFolder: index == folder.guilds.count - 1
                    ))
                }
            }
        }
        return tiles
    }

    /// The rail as the settings list it is drawn from, for the rules.
    private var arrangement: [GuildFolder] {
        items.map { item in
            switch item {
            case .guild(let guild): GuildFolder(guildIDs: [guild.id])
            case .folder(let folder): GuildFolder(id: folder.id, guildIDs: folder.guilds.map(\.id))
            }
        }
    }

    // MARK: Scrolling while carrying

    private func updateAutoscroll() {
        guard velocity != 0 else {
            autoscroll?.cancel()
            autoscroll = nil
            return
        }
        guard autoscroll == nil else { return }
        autoscroll = Task { [weak self] in
            while !Task.isCancelled {
                self?.step()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// How far to scroll this frame: toward the edge the pointer is within
    /// reach of, faster the closer it is.
    ///
    /// **Measured from what shows, not from the clip view's edge**: the rail
    /// runs up under the window's titlebar, and the clip view's insets are
    /// the part of it nobody can see.
    private var velocity: CGFloat {
        guard isActive, let clip = scrollView?.contentView else { return 0 }
        let insets = clip.contentInsets
        let y = location.y - (clip.bounds.minY + insets.top)
        if y < Self.edge { return -Self.speed * (1 - max(0, y) / Self.edge) }
        let foot = clip.bounds.height - insets.top - insets.bottom - y
        if foot < Self.edge { return Self.speed * (1 - max(0, foot) / Self.edge) }
        return 0
    }

    private func step() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        // At rest the clip view sits at minus its top inset, not at zero.
        let lower = -clip.contentInsets.top
        let upper = max(lower, document.frame.height - clip.bounds.height + clip.contentInsets.bottom)
        let from = clip.bounds.minY
        let to = min(max(lower, from + velocity), upper)
        guard to != from else {
            autoscroll?.cancel()
            autoscroll = nil
            return
        }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: to))
        scrollView.reflectScrolledClipView(clip)
        // The rail moved under a pointer that did not: what it is over is
        // further along by the same amount.
        location.y += to - from
        retarget()
    }
}

// MARK: - Carrying a tile

extension View {
    /// Makes this tile one the reader can pick up and move.
    ///
    /// **Beside the tile's own click, not instead of it** — a press that does
    /// not travel four points is still the click that opens the server — and
    /// its frame is recorded as it lays out, in the rail's content space.
    func railDraggable(_ node: RailNodeID?, drag: RailDrag?) -> some View {
        modifier(RailDraggable(node: node, drag: drag))
    }
}

private struct RailDraggable: ViewModifier {
    var node: RailNodeID?
    var drag: RailDrag?

    /// Resets itself when the gesture is taken away without ending — the
    /// window losing the pointer — which `onEnded` does not report.
    @GestureState private var isCarrying = false

    func body(content: Content) -> some View {
        if let node, let drag {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(GuildRail.contentSpace)) } action: {
                    drag.frames[node] = $0
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(GuildRail.contentSpace))
                        .updating($isCarrying) { _, state, _ in state = true }
                        .onChanged { drag.changed(node, at: $0.location) }
                        .onEnded { drag.ended(at: $0.location) }
                )
                .onChange(of: isCarrying) { _, carrying in
                    if !carrying { drag.ended(at: nil) }
                }
                .opacity(drag.source == node ? 0.35 : 1)
        } else {
            content
        }
    }
}

// MARK: - What the carry draws

/// Discord's marks, over the rail's content: a line where the entry would go,
/// a ring around the tile it would go into, and the tile itself under the
/// pointer. **Discord's green** — `--status-positive` — for both marks.
struct RailDropMarks: View {
    var drag: RailDrag
    var items: [RailItem]

    private static let lineInset: CGFloat = 8

    var body: some View {
        if let source = drag.source {
            ZStack(alignment: .topLeading) {
                switch drag.target?.mark {
                case .line(let y):
                    Capsule()
                        .fill(Palette.presenceOnline)
                        .frame(width: Proportions.railWidth - Self.lineInset * 2, height: 4)
                        .shadow(color: .black.opacity(0.28), radius: 1.5)
                        .position(x: Proportions.railWidth / 2, y: y)
                case .ring(let node):
                    if let frame = drag.frames[node] {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.presenceOnline, lineWidth: 2)
                            .frame(width: Metrics.guildTile + 6, height: Metrics.guildTile + 6)
                            .position(x: frame.midX, y: frame.midY)
                    }
                case nil:
                    EmptyView()
                }
                RailDragPreview(node: source, items: items)
                    .position(drag.location)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The tile under the pointer while it is carried.
private struct RailDragPreview: View {
    var node: RailNodeID
    var items: [RailItem]

    private var side: CGFloat { Metrics.guildTile }

    var body: some View {
        Group {
            switch node {
            case .guild(let guildID):
                if let guild = guild(guildID) {
                    RemoteImage(url: guild.iconURL, side: side) {
                        Text(guild.monogram)
                            .font(.system(size: side * 0.30, weight: .bold))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: side, height: side)
                            .background(Palette.surfaceRaised)
                    }
                    .frame(width: side, height: side)
                    .clipShape(.circle)
                }
            case .folder(let folderID):
                let tint = folder(folderID)?.colorValue.map { Color(hex: $0) } ?? Color(hex: RailFolder.defaultColor)
                Image(systemName: "folder.fill")
                    .font(.system(size: side * 0.36))
                    .foregroundStyle(tint)
                    .frame(width: side, height: side)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surfaceRaised))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .opacity(0.9)
    }

    private func guild(_ id: GuildID) -> RailGuild? {
        for item in items {
            switch item {
            case .guild(let guild) where guild.id == id: return guild
            case .folder(let folder):
                if let guild = folder.guilds.first(where: { $0.id == id }) { return guild }
            default: continue
            }
        }
        return nil
    }

    private func folder(_ id: UInt64) -> RailFolder? {
        for case .folder(let folder) in items where folder.id == id { return folder }
        return nil
    }
}

/// Finds the scroll view the rail is inside, for the carry to scroll.
///
/// **One layer-less view, read once it is in a window.** SwiftUI's `ScrollView`
/// on the Mac is an `NSScrollView`, and scrolling its clip view directly moves
/// the rail without writing any state a view is invalidated by — which a
/// scroll position bound into the rail would, sixty times a second.
struct RailScrollViewReader: NSViewRepresentable {
    var drag: RailDrag

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.drag = drag
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.drag = drag
    }

    final class ReaderView: NSView {
        weak var drag: RailDrag?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            drag?.scrollView = enclosingScrollView
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
