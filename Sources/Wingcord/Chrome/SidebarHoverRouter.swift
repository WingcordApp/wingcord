import AppKit
import SwiftUI
import WingcordCore

/// Which row of one sidebar list the pointer is on, worked out once for the
/// list rather than once per row.
///
/// **A row's `.onHover` was a quarter of what scrolling the channel list cost**
/// (measured 2026-11-11, docs/PERFORMANCE.md). SwiftUI compiles it to a
/// tracking area and a responder per row; AppKit re-derives every visible
/// row's tracking area on every frame of a scroll, and each row passing under
/// a resting pointer flipped its hover, ran its body and started its fade. A
/// list of thirty rows on screen paid for thirty of those to know one thing:
/// which row the pointer is on.
///
/// Here the list has **one** tracking area (`SidebarHoverSurfaceView`, behind
/// the list), and each row already carries one small `NSView` — the catcher its
/// right-click needs. That view is the row's agent: the router asks which
/// agent's box holds the pointer and tells that row, and no other, that it is
/// hovered.
///
/// - **Nothing is hovered during a scroll**, as on the drawn lists: the rows
///   are moving and the pointer is not choosing among them. When the scroll
///   ends the row under the pointer is asked for once, from where the pointer
///   is — which SwiftUI's own hover never did until the pointer next moved.
/// - **A row under something else is not hovered.** The now bar and the call
///   card float over the list's foot; the pointer on them is not on the row
///   beneath. The window is asked what is actually under the point.
/// - **The list's scroll is a scroll for the whole app** (`ScrollWorkGate`),
///   which the channel list had never said.
@MainActor
final class SidebarHoverRouter {
    private let agents = NSHashTable<SidebarRowAgentView>.weakObjects()
    private weak var scrollView: NSScrollView?
    private weak var hovered: SidebarRowAgentView?
    private var observers: [NSObjectProtocol] = []
    private var isScrolling = false
    private var scrollTimeout: Task<Void, Never>?
    /// Whether the pointer is inside the list at all, by the surface's account.
    private var isPointerInside = false

    /// How many rows have been told they are hovered: what a test reads.
    private(set) var hoverChanges = 0

    // MARK: Rows

    func attach(_ agent: SidebarRowAgentView) {
        agents.add(agent)
        guard scrollView == nil, let found = agent.enclosingScrollView else { return }
        watch(found)
    }

    func detach(_ agent: SidebarRowAgentView) {
        agents.remove(agent)
        // A row taken away under the pointer is never told the pointer left —
        // nor is its flyout, which would stay up beside a row that is gone.
        if hovered === agent {
            hovered = nil
            if let id = agent.activePostsChannelID { ActivePostsFlyout.shared.pointerLeftRow(id) }
        }
    }

    // MARK: The pointer

    /// The pointer moved inside the list, or came into it.
    func pointerMoved(to windowPoint: NSPoint, in window: NSWindow?) {
        isPointerInside = true
        resolve(windowPoint, in: window)
    }

    func pointerLeft() {
        isPointerInside = false
        setHovered(nil)
    }

    /// Asks again from where the pointer is now — after a scroll, or after the
    /// rows moved under a pointer that did not.
    func resolveFromPointer() {
        guard isPointerInside, let window = scrollView?.window else { return }
        resolve(window.mouseLocationOutsideOfEventStream, in: window)
    }

    private func resolve(_ windowPoint: NSPoint, in window: NSWindow?) {
        guard !isScrolling, let window, let content = window.contentView else {
            setHovered(nil)
            return
        }
        // What is really under the point: a bar floating over the list's foot
        // takes the pointer, and the row beneath it does not.
        if let scrollView {
            let inFrame = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
            guard let hit = content.hitTest(inFrame),
                  hit === scrollView || hit.isDescendant(of: scrollView)
            else {
                setHovered(nil)
                return
            }
        }
        // The smallest box that holds the point: a tile in a grid inside a row
        // is the tile, not the row.
        var best: SidebarRowAgentView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for agent in agents.allObjects where agent.window === window && agent.takesHover {
            guard agent.bounds.contains(agent.convert(windowPoint, from: nil)),
                  !agent.isHiddenOrHasHiddenAncestor
            else { continue }
            let area = agent.bounds.width * agent.bounds.height
            if area < bestArea {
                best = agent
                bestArea = area
            }
        }
        setHovered(best)
    }

    private func setHovered(_ agent: SidebarRowAgentView?) {
        guard agent !== hovered else { return }
        let previous = hovered
        hovered = agent
        previous?.onHover?(false)
        agent?.onHover?(true)
        hoverChanges += 1
        // **The flyout hangs off the row's own view**, which only the router
        // holds — one presenter for the list, never a popover per row (§2).
        if let id = previous?.activePostsChannelID {
            ActivePostsFlyout.shared.pointerLeftRow(id)
        }
        if let agent, let id = agent.activePostsChannelID {
            ActivePostsFlyout.shared.pointerEnteredRow(id, anchor: agent)
        }
    }

    // MARK: The scroll

    private func watch(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScrolling(true) }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScrolling(false) }
        })
        // A scroll nobody's hand made — the arrow keys, a jump to the open
        // channel — moves the rows under a resting pointer too.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isScrolling, self.isPointerInside else { return }
                self.resolveFromPointer()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setHovered(nil) }
        })
    }

    private func setScrolling(_ scrolling: Bool) {
        scrollTimeout?.cancel()
        scrollTimeout = nil
        isScrolling = scrolling
        let owner = ObjectIdentifier(self)
        if scrolling {
            setHovered(nil)
            ScrollWorkGate.begin(owner: owner)
            // A gesture whose end never arrives must not hold the gate, and
            // with it every piece of optional work in the app.
            scrollTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.setScrolling(false)
            }
        } else {
            ScrollWorkGate.endIfOwned(by: owner)
            resolveFromPointer()
        }
    }

    /// **The gate goes with the router, whatever else does.** The router is
    /// a list's `@State` and its surface holds it weakly, so a list torn down
    /// mid-scroll — a swipe to the other page while momentum is still running
    /// — could free it before `dismantleNSView` asked it to tear down, with
    /// the app-wide gate still held in its name and its timeout's weak
    /// reference already gone. That stopped every drawn surface's pictures
    /// for the rest of the run (WC-0AQB, WC-E5V8). The gate is thread-safe
    /// and keyed by identity, so this is safe from any thread.
    nonisolated deinit {
        ScrollWorkGate.endIfOwned(by: ObjectIdentifier(self))
    }

    /// Lets go of everything: the list is going away.
    func tearDown() {
        scrollTimeout?.cancel()
        scrollTimeout = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        ScrollWorkGate.endIfOwned(by: ObjectIdentifier(self))
        isScrolling = false
        setHovered(nil)
        scrollView = nil
    }
}

extension EnvironmentValues {
    /// The list's hover router, where a list has one. A reference that never
    /// changes for the life of the list (`INVARIANTS.md` §2: an environment
    /// value is a constant or a reference).
    @Entry var sidebarHoverRouter: SidebarHoverRouter? = nil
}

// MARK: - The list's one tracking area

/// Behind the list, the size of the list: the one tracking area hover is read
/// from. It takes no clicks.
struct SidebarHoverSurface: NSViewRepresentable {
    var router: SidebarHoverRouter

    func makeNSView(context: Context) -> SidebarHoverSurfaceView {
        let view = SidebarHoverSurfaceView()
        view.router = router
        return view
    }

    func updateNSView(_ view: SidebarHoverSurfaceView, context: Context) {
        view.router = router
    }

    static func dismantleNSView(_ view: SidebarHoverSurfaceView, coordinator: ()) {
        view.router?.tearDown()
        view.router = nil
    }
}

final class SidebarHoverSurfaceView: NSView {
    weak var router: SidebarHoverRouter?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(next)
        area = next
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        router?.pointerMoved(to: event.locationInWindow, in: window)
    }

    override func mouseMoved(with event: NSEvent) {
        router?.pointerMoved(to: event.locationInWindow, in: window)
    }

    override func mouseExited(with event: NSEvent) {
        router?.pointerLeft()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { router?.pointerLeft() }
    }
}

// MARK: - A row's agent

/// The one `NSView` a sidebar row carries: its right-click, its hover, and the
/// switch that turns the system's selection highlight off for its list.
///
/// Three views a row used to make — a catcher, a highlight suppressor, and the
/// tracking area behind `.onHover` — and a platform view is the dearest thing
/// a SwiftUI row can hold.
struct SidebarRowAgent: NSViewRepresentable {
    var router: SidebarHoverRouter
    /// Nil for a row with no menu, which then takes no click at all.
    var onClick: ((CGRect) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// The channel whose active posts this row offers under the pointer.
    var activePostsChannelID: ChannelID? = nil

    func makeNSView(context: Context) -> SidebarRowAgentView {
        let view = SidebarRowAgentView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: SidebarRowAgentView, context: Context) {
        // Refreshed rather than captured once, as the catcher's is.
        apply(to: view)
    }

    private func apply(to view: SidebarRowAgentView) {
        view.router = router
        view.takesClicks = onClick != nil
        view.onClick = onClick ?? { _ in }
        view.onHover = onHover
        view.activePostsChannelID = activePostsChannelID
    }

    static func dismantleNSView(_ view: SidebarRowAgentView, coordinator: ()) {
        view.router?.detach(view)
        view.onHover = nil
    }
}

final class SidebarRowAgentView: SecondaryClickCatcher.CatcherView {
    weak var router: SidebarHoverRouter?
    var onHover: ((Bool) -> Void)?
    /// See `SidebarRowAgent.activePostsChannelID`.
    var activePostsChannelID: ChannelID?
    var takesClicks = true
    var takesHover: Bool { onHover != nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        takesClicks ? super.hitTest(point) : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            router?.detach(self)
            return
        }
        router?.attach(self)
        // **Before the row's first draw** — see
        // `SystemSelectionHighlightSuppressor`, whose job this is here.
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                return
            }
            ancestor = view.superview
        }
    }
}

// MARK: - What a row asks for

/// A row's pointer: hover, and a right-click where it has a menu.
///
/// **Through the list's router where there is one**, and through SwiftUI's own
/// hover and the plain catcher where there is not — a row drawn outside a
/// sidebar list, a preview, a test. Which it is never changes for a row, so
/// the branch is not a change of identity.
struct SidebarRowPointer: ViewModifier {
    var openMenu: ((CGRect) -> Void)?
    /// The channel whose active posts the row offers — `ActivePostsFlyout`.
    var activePostsChannelID: ChannelID? = nil
    var hover: (Bool) -> Void

    @Environment(\.sidebarHoverRouter) private var router

    func body(content: Content) -> some View {
        if let router {
            content.overlay {
                SidebarRowAgent(
                    router: router, onClick: openMenu, onHover: hover,
                    activePostsChannelID: activePostsChannelID
                )
            }
        } else {
            content
                .background { SystemSelectionHighlightSuppressor().allowsHitTesting(false) }
                .onHover(perform: hover)
                .modifier(SecondaryClickFallback(openMenu: openMenu))
        }
    }
}

/// The catcher, or nothing — the modifier is guarded, not the closure (§2).
private struct SecondaryClickFallback: ViewModifier {
    var openMenu: ((CGRect) -> Void)?

    func body(content: Content) -> some View {
        if let openMenu {
            content.onSecondaryClick(perform: openMenu)
        } else {
            content
        }
    }
}
