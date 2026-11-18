import AppKit
import SwiftUI
import WingcordCore

// MARK: - The pager's state

/// Which page the sidebar shows, and how far fingers have dragged it
/// (REDESIGN.md R8).
///
/// **A view's state, not the selection.** Swiping to the conversations while a
/// server channel is open changes nothing in the detail column — the page is
/// which list the reader is looking at, as in Discord's mobile app and Craft's
/// sidebar. The selection moves the page only when it lands somewhere the page
/// does not show (`follow(selectedGuildID:)`).
@Observable
@MainActor
final class SidebarPager {
    static let shared = SidebarPager()

    /// The page on screen, as an index into the layout's pages.
    private(set) var index = 0
    /// How far the pages have been dragged off `index`, in points: live while
    /// fingers are on the trackpad, zero at rest.
    private(set) var drag: CGFloat = 0
    /// Whether fingers are dragging the pages now.
    private(set) var isTracking = false
    /// The server the servers pages show: the selected one, or the last one
    /// opened while a conversation is selected. Nil until one has been.
    private(set) var guildID: GuildID?
    /// How far the rack is expanded over the servers page (REDESIGN.md R10):
    /// 0 is the rail beside the channels, 1 every server by name across the
    /// page. Live under the fingers, sprung at rest.
    private(set) var rackProgress: CGFloat = 0
    /// Whether the pages are faded out mid-switch — Reduce Motion's page
    /// change, a dissolve in place of the slide.
    private(set) var isDissolving = false

    /// What a gesture is moving: the pages, or the rack from where it was.
    private enum Grip {
        case pages
        case rack(from: CGFloat)
    }
    private var grip = Grip.pages

    /// How far across the page the fingers travel to expand the rack fully.
    private static let rackTravelShare: CGFloat = 0.6

    private var settings: AppSettings { .shared }

    var pages: [SidebarPage] { settings.sidebarPages.pages }
    var page: SidebarPage { pages[min(index, pages.count - 1)] }

    /// Where the pages sit, as a fraction of a page — the switcher's
    /// selection rides this, so it moves with the fingers.
    func position(width: CGFloat) -> CGFloat {
        guard width > 0 else { return CGFloat(index) }
        return CGFloat(index) - drag / width
    }

    // MARK: Going to a page

    /// Shows `page`, sliding on the reposition spring.
    func show(_ page: SidebarPage, animated: Bool = true) {
        guard let target = pages.firstIndex(of: page) else { return }
        go(to: target, animated: animated)
    }

    /// One page along — the keyboard's ⌃⌘← and ⌃⌘→.
    func step(_ delta: Int) {
        go(to: min(max(index + delta, 0), pages.count - 1), animated: true)
    }

    private func go(to target: Int, animated: Bool) {
        guard target != index || drag != 0 else { return }
        let collapses = pages[target] != .servers
        if animated, Self.motion.reduceMotion {
            // **Reduce Motion: a dissolve, not a slide.** The pages fade out,
            // move while nothing shows, and fade back in on the new one — no
            // travel across the panel.
            withAnimation(Motion.fadeQuick) { isDissolving = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.fadeQuickDuration) { [weak self] in
                guard let self else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    index = target
                    drag = 0
                    if collapses { rackProgress = 0 }
                }
                withAnimation(Motion.fade) { isDissolving = false }
            }
        } else if animated {
            withAnimation(Self.motion.reposition) {
                index = target
                drag = 0
                if collapses { rackProgress = 0 }
            }
        } else {
            index = target
            drag = 0
            if collapses { rackProgress = 0 }
        }
    }

    // MARK: The rack

    /// Whether the rack is expanded, as a committed state.
    var isRackExpanded: Bool { rackProgress > 0.5 }

    /// Whether the rack can expand where the pages are: the two-page layout's
    /// servers page with a server open. With none open that page IS the list,
    /// and the three-stop layout gives the list a page of its own.
    var canExpandRack: Bool { page == .servers && guildID != nil }

    func setRackExpanded(_ expanded: Bool, animated: Bool = true) {
        let target: CGFloat = expanded ? 1 : 0
        guard rackProgress != target else { return }
        if animated {
            withAnimation(Self.motion.reposition) { rackProgress = target }
        } else {
            rackProgress = target
        }
    }

    /// Show All Servers — the rail's button and the View menu's command: the
    /// list, from wherever the pages are.
    func toggleAllServers() {
        if canExpandRack {
            setRackExpanded(!isRackExpanded)
        } else if pages.contains(.serverList) {
            show(page == .serverList ? (guildID == nil ? .messages : .channels) : .serverList)
        } else if pages.contains(.servers) {
            show(.servers)
            if guildID != nil { setRackExpanded(true) }
        }
    }

    /// The selection moved: a conversation shows the conversations, a server
    /// its channels — unless the page on screen already shows it.
    func follow(selectedGuildID: GuildID?, animated: Bool = true) {
        if let selectedGuildID {
            // Picking a server in the expanded rack is going to it: the list
            // gives way to its channels.
            if selectedGuildID != guildID { setRackExpanded(false, animated: animated) }
            guildID = selectedGuildID
            switch page {
            case .servers, .channels: return
            case .messages, .serverList:
                show(pages.contains(.servers) ? .servers : .channels, animated: animated)
            }
        } else if page != .messages {
            show(.messages, animated: animated)
        }
    }

    /// The layout changed under the pager: keep the page that shows the same
    /// thing, or the nearest.
    func layoutChanged(from old: SidebarPageLayout, to new: SidebarPageLayout) {
        let shown = old.pages[min(index, old.pages.count - 1)]
        let equivalent: SidebarPage = switch shown {
        case .messages: .messages
        case .servers: new == .twoPages ? .servers : .channels
        case .serverList: new == .twoPages ? .servers : .serverList
        case .channels: new == .twoPages ? .servers : .channels
        }
        index = new.pages.firstIndex(of: equivalent) ?? 0
        drag = 0
    }

    // MARK: Fingers

    /// Fingers came down and moved sideways.
    ///
    /// **Which thing they move is decided here, once**, from where they
    /// started and which way they went — Discord's mobile gesture: on the
    /// servers page a swipe that starts on the rack and goes right draws the
    /// list over the channels, and with the list out a swipe left puts it
    /// away. Everything else moves the pages.
    ///
    /// - Parameters:
    ///   - startX: where the fingers came down, from the page's leading edge.
    ///   - direction: the sign of the first sideways movement.
    func beginTracking(startX: CGFloat, direction: CGFloat) {
        isTracking = true
        grip = .pages
        guard canExpandRack else { return }
        if !isRackExpanded, direction > 0, startX <= Proportions.railWidth {
            grip = .rack(from: rackProgress)
        } else if isRackExpanded, direction < 0 {
            grip = .rack(from: rackProgress)
        }
    }

    /// The pages follow the fingers 1:1 inside their range and rubber-band
    /// past the first and the last — or the rack does, inside its own.
    func track(_ translation: CGFloat, width: CGFloat) {
        guard isTracking, width > 0 else { return }
        if case .rack(let from) = grip {
            let distance = width * Self.rackTravelShare
            let position = Motion.clampWithResistance(from * distance + translation, to: 0...distance, limit: distance)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { rackProgress = position / distance }
            return
        }
        let base = -CGFloat(index) * width
        let furthest = -CGFloat(pages.count - 1) * width
        let offset = Motion.clampWithResistance(base + translation, to: furthest...0, limit: width)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag = offset - base }
    }

    /// Lets go: the page the flick is heading for, by its projected resting
    /// point rather than where the fingers left it, one page at most — and the
    /// spring starts at the fingers' own speed.
    func endTracking(velocity: CGFloat, width: CGFloat) {
        guard isTracking else { return }
        isTracking = false
        if case .rack = grip {
            grip = .pages
            let distance = max(1, width * Self.rackTravelShare)
            let current = rackProgress * distance
            let projected = Motion.projectedPosition(from: current, velocity: velocity, decelerationRate: 0.99)
            let target: CGFloat = projected > distance / 2 ? 1 : 0
            withAnimation(Self.motion.handoff(velocity: velocity, over: target * distance - current)) {
                rackProgress = target
            }
            return
        }
        guard width > 0 else {
            go(to: index, animated: true)
            return
        }
        let current = -CGFloat(index) * width + drag
        // The paging rate, not the scroll view's: a page is a short throw.
        let projected = Motion.projectedPosition(from: current, velocity: velocity, decelerationRate: 0.99)
        let target = min(max(Int((-projected / width).rounded()), index - 1, 0), index + 1, pages.count - 1)
        let destination = -CGFloat(target) * width
        withAnimation(Self.motion.handoff(velocity: velocity, over: destination - current)) {
            index = target
            drag = 0
            // Leaving the servers page puts the list away.
            if pages[target] != .servers { rackProgress = 0 }
        }
    }

    /// Reduce Motion, read when an animation starts — the pager is not a view
    /// and cannot hold the environment's resolver.
    private static var motion: MotionResolver {
        MotionResolver(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

// MARK: - The pages

/// The sidebar's pages side by side, one panel wide each, sliding under the
/// fingers (REDESIGN.md R8).
///
/// **Every page stays alive**, so a swipe reveals a list that is already laid
/// out rather than one building under the fingers; only the offset moves, and
/// an offset is a property of the layer the render server already has.
struct SidebarPages: View {
    @Environment(AppModel.self) private var model
    @State private var pager = SidebarPager.shared
    @State private var settings = AppSettings.shared
    @State private var width: CGFloat = 0

    var body: some View {
        // **A reader, not a measured stack.** The reader takes the width it is
        // offered and never asks its content; measuring the row of pages
        // instead fed their own width back to them — each page as wide as the
        // row, the row as wide as two pages — and the layout never settled.
        GeometryReader { proxy in
            let pageWidth = proxy.size.width
            HStack(spacing: 0) {
                ForEach(Array(pager.pages.enumerated()), id: \.element) { index, page in
                    SidebarPageView(page: page, guildID: pager.guildID)
                        .frame(width: pageWidth)
                        // Only the page on screen takes a click: the others sit
                        // beside the panel, over the detail column, where a
                        // clip hides them but would not stop a click.
                        .allowsHitTesting(index == pager.index && !pager.isTracking)
                        .accessibilityHidden(index != pager.index)
                }
            }
            .offset(x: -CGFloat(pager.index) * pageWidth + pager.drag)
            .opacity(pager.isDissolving ? 0 : 1)
            .frame(width: pageWidth, height: proxy.size.height, alignment: .leading)
        }
        // **Down under the call card and the now bar** (Alex, 2026-10-15). The
        // bars are the panel's bottom safe-area inset, and a reader that
        // respects it stopped every list at the bars' top edge — so nothing
        // ever passed under the now bar's clear glass. Reaching under them,
        // each list is handed the bars' height as its safe area instead: rows
        // scroll beneath the glass, and the last one still comes to rest above
        // it.
        .ignoresSafeArea(.container, edges: .bottom)
        // **No clip of its own.** The panel clips to its silhouette already,
        // and a clip here would also cut what a page draws above itself on
        // purpose — the banner and the travelling title, up under the header.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background {
            SidebarSwipeCatcher(
                began: { pager.beginTracking(startX: $0, direction: $1) },
                changed: { pager.track($0, width: width) },
                ended: { pager.endTracking(velocity: $0, width: width) }
            )
        }
        .onChange(of: model.selectedGuildID, initial: true) { old, new in
            // The first answer places the pages without travel: a launch
            // opens on the page the selection is on.
            pager.follow(selectedGuildID: new, animated: old != new)
        }
        .onChange(of: settings.sidebarPages) { old, new in
            pager.layoutChanged(from: old, to: new)
        }
    }
}

/// One page's list.
private struct SidebarPageView: View {
    var page: SidebarPage
    var guildID: GuildID?

    @Environment(\.shellLayout) private var layout
    @Environment(\.motion) private var motion
    @State private var pager = SidebarPager.shared

    /// How far the list and the channels travel as they trade places.
    private static let rackSlide: CGFloat = 36

    var body: some View {
        switch page {
        case .messages:
            ChannelSidebarContainer(guildID: nil)
                // No rail beside it: the title clears the traffic lights.
                .environment(\.sidebarTitleLeading, layout?.pageTitleLeading ?? SidebarBannerLayout.headerTitleLeading)
        case .servers:
            if let guildID {
                // The rack, expanded over the channels: the list slides in from
                // the rail's side as the rail and the channels give way to it —
                // a crossfade with a short travel, which reads as the rail
                // opening out. Under Reduce Motion, the crossfade alone.
                let progress = pager.rackProgress
                let travel = motion.reduceMotion ? 0 : Self.rackSlide
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        GuildRailContainer(showsAllServersButton: true)
                            .fadesUnderSidebarChrome()
                        ChannelSidebarContainer(guildID: guildID)
                    }
                    .opacity(1 - progress)
                    .offset(x: progress * travel)
                    .allowsHitTesting(progress < 0.5)
                    .accessibilityHidden(progress >= 0.5)
                    if progress > 0 {
                        ServerListContainer()
                            .opacity(progress)
                            .offset(x: -(1 - progress) * travel)
                            .allowsHitTesting(progress >= 0.5)
                            .accessibilityHidden(progress < 0.5)
                    }
                }
            } else {
                ServerListContainer()
            }
        case .serverList:
            ServerListContainer()
        case .channels:
            if let guildID {
                ChannelSidebarContainer(guildID: guildID)
                    .environment(\.sidebarTitleLeading, layout?.pageTitleLeading ?? SidebarBannerLayout.headerTitleLeading)
            } else {
                ServerListContainer()
            }
        }
    }
}

// MARK: - The chrome over the pages

extension View {
    /// Fades a list out under the panel's header and page switcher, so rows
    /// scrolled up pass under the chrome rather than through it — the
    /// transcript's `TranscriptTopFade`, for the sidebar's lists.
    ///
    /// **The list's own top is the chrome's foot** — measured: every page's
    /// list is laid out from there, and only its scroll view draws rows up
    /// into the chrome. A mask is the list's size, so it hides those rows
    /// whole and fades the first few points below the switcher.
    func fadesUnderSidebarChrome() -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                    .frame(height: SidebarChromeFade.run)
                Color.white
            }
            .allowsHitTesting(false)
        }
    }
}

nonisolated enum SidebarChromeFade {
    /// How far below the switcher a row takes to come back whole.
    static let run: CGFloat = 14
}

/// The sidebar panel's own coordinate space: its top is the panel's top edge,
/// where the header row begins. A page measures itself in it to put its title
/// in that row.
nonisolated enum SidebarPanelSpace {
    static let name = "SidebarPanel"
    static var space: NamedCoordinateSpace { .named(name) }
}

extension EnvironmentValues {
    /// Where a page's header title starts, from the page's leading edge — past
    /// the traffic lights on a page with no rail beside it.
    @Entry var sidebarTitleLeading: CGFloat = SidebarBannerLayout.headerTitleLeading
    /// The header row's height, which a page's travelling title centres in. The
    /// chrome above a page is taller than the row by the page switcher.
    @Entry var sidebarHeaderBand: CGFloat?
    /// The shell's geometry, for the views inside the panel that place
    /// themselves against the traffic lights.
    @Entry var shellLayout: ShellLayout?
    /// How tall the call card and the now bar stand over the foot of the
    /// pages, which every sidebar list takes as its bottom safe-area padding.
    ///
    /// **Handed down, because the safe area never arrives.** The pages ignore
    /// the bottom inset so their rows can pass under the bars' glass, and a
    /// macOS `List` given that region by an ancestor takes no content inset
    /// from it — measured in a probe, and in the demo: the last channels sat
    /// under the bars, out of reach, with the rubber band springing them back.
    /// `safeAreaPadding` on the list itself is the one form that insets it.
    @Entry var sidebarBarsInset: CGFloat = 0
    /// The reader's channel and category spacing — `AppSettings.channelSpacing`
    /// and `categorySpacing` — for the channel list's rows to read.
    @Entry var sidebarListSpacing = SidebarListSpacing()
}

/// How much air the channel list puts between its rows and above its
/// categories, on top of the system sidebar's own — see `AppSettings`.
struct SidebarListSpacing: Equatable, Sendable {
    var channel: CGFloat = 0
    var category: CGFloat = 0

    /// A channel row's content height at this spacing.
    var channelRowContent: CGFloat { max(16, Metrics.sidebarRowContent + channel) }
    /// The room above a category heading at this spacing.
    var categoryTop: CGFloat { max(0, Spacing.tight + category) }
}

// MARK: - The switcher

/// The pages, named — the system's capsule strip (`SegmentedPicker`, as the
/// inbox's) under the panel's header, as Xcode's navigator keeps its tabs
/// under its toolbar. Its selection follows the fingers: it moves to the next
/// page the moment a swipe carries the pages past halfway.
struct SidebarPageSwitcher: View {
    @State private var pager = SidebarPager.shared
    /// The panel's width, which the pages' position is measured in.
    var pageWidth: CGFloat

    /// The extra-large strip's height.
    static let height: CGFloat = 36

    var body: some View {
        let pages = pager.pages
        let shown = min(max(Int(pager.position(width: pageWidth).rounded()), 0), pages.count - 1)
        SegmentedPicker(
            options: pages.map { .init($0, $0.title) },
            selection: Binding(
                get: { pages[shown] },
                set: { pager.show($0) }
            ),
            fillsWidth: true
        )
        .accessibilityLabel(Text("Sidebar pages"))
    }
}

// MARK: - Fingers on the trackpad

/// Watches two-finger horizontal swipes over the sidebar and hands them to the
/// pager, leaving every vertical scroll to the lists under it.
///
/// **A local event monitor, not a gesture.** SwiftUI has no two-finger swipe
/// on macOS, and the lists' own scroll views take every scroll event that
/// lands on them. The monitor sees each event first: a gesture that starts
/// mostly sideways is claimed — its events, momentum included, never reach the
/// lists — and anything else passes through untouched.
private struct SidebarSwipeCatcher: NSViewRepresentable {
    var began: (CGFloat, CGFloat) -> Void
    var changed: (CGFloat) -> Void
    var ended: (CGFloat) -> Void

    func makeNSView(context: Context) -> SwipeCatcherView {
        let view = SwipeCatcherView()
        view.handlers = (began, changed, ended)
        return view
    }

    func updateNSView(_ view: SwipeCatcherView, context: Context) {
        view.handlers = (began, changed, ended)
    }

    static func dismantleNSView(_ view: SwipeCatcherView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor
final class SwipeCatcherView: NSView {
    var handlers: (began: (CGFloat, CGFloat) -> Void, changed: (CGFloat) -> Void, ended: (CGFloat) -> Void)?
    /// Where the gesture's fingers came down, from this view's leading edge.
    private var startX: CGFloat = 0

    private var monitor: Any?
    private enum Phase {
        case idle
        /// Fingers down over the panel, direction not yet decided: the
        /// gesture's events are held back, not delivered.
        case deciding(dx: CGFloat, dy: CGFloat)
        /// Claimed: the pages follow.
        case tracking
        /// Not ours — vertical, or elsewhere: everything passes until the
        /// next gesture.
        case passing
        /// Lifted after a claim: the momentum that follows is swallowed too.
        case coasting
    }
    private var phase = Phase.idle
    /// The gesture's opening events, held while its direction is decided.
    ///
    /// **Held, not passed and not dropped.** A list's scroll view that is
    /// handed a gesture's first event takes the rest of the gesture straight
    /// off the queue in its own tracking loop, where no monitor sees it — so
    /// the decision has to be made before the list hears of the gesture at
    /// all. A vertical one gets its events back, in order, the moment it is
    /// known to be vertical.
    private var held: [NSEvent] = []
    /// The timestamps of events put back on the queue, so they pass when they
    /// come round again.
    private var replayed: Set<TimeInterval> = []
    private var translation: CGFloat = 0
    /// Recent movement, for the release velocity.
    private var samples: [(time: TimeInterval, dx: CGFloat)] = []

    /// How far the fingers move before the direction is decided, and how much
    /// more sideways than upright a swipe has to be to be the pager's.
    private static let decisionDistance: CGFloat = 4
    private static let sidewaysRatio: CGFloat = 1.3

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // Nil swallows the event: a claimed or held one never reaches the
            // lists from here.
            return self.handle(event) ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether the event was taken — claimed, or held.
    private func handle(_ event: NSEvent) -> Bool {
        if replayed.remove(event.timestamp) != nil { return false }
        // A momentum tail: the pager's after a claim, the lists' otherwise.
        if !event.momentumPhase.isEmpty {
            guard case .coasting = phase else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { phase = .idle }
            return true
        }
        let starting = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        if starting {
            if case .deciding = phase, event.phase.contains(.began) {
                // The fingers that touched have started moving: one gesture.
            } else if event.window === window, event.hasPreciseScrollingDeltas,
                      bounds.contains(convert(event.locationInWindow, from: nil)) {
                // Only gestures that start over this panel, in this window,
                // from a trackpad — a wheel has no phases and no sideways
                // intent.
                phase = .deciding(dx: 0, dy: 0)
                startX = convert(event.locationInWindow, from: nil).x
                held.removeAll(keepingCapacity: true)
                replayed.removeAll()
                translation = 0
                samples.removeAll(keepingCapacity: true)
            } else {
                phase = .passing
                return false
            }
        }
        let ending = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        switch phase {
        case .idle, .passing, .coasting:
            if ending, case .passing = phase { phase = .idle }
            return false
        case .deciding(let dx, let dy):
            held.append(event)
            if ending {
                // Too short to call: whatever it was belongs to the list.
                phase = .passing
                replayHeld()
                return true
            }
            let x = dx + event.scrollingDeltaX, y = dy + event.scrollingDeltaY
            guard abs(x) + abs(y) >= Self.decisionDistance else {
                phase = .deciding(dx: x, dy: y)
                return true
            }
            if abs(x) > abs(y) * Self.sidewaysRatio {
                phase = .tracking
                held.removeAll(keepingCapacity: true)
                translation = x
                record(event, dx: x)
                handlers?.began(startX, x)
                handlers?.changed(translation)
            } else {
                phase = .passing
                replayHeld()
            }
            return true
        case .tracking:
            if ending {
                phase = .coasting
                handlers?.ended(velocity(at: event.timestamp))
                return true
            }
            translation += event.scrollingDeltaX
            record(event, dx: event.scrollingDeltaX)
            handlers?.changed(translation)
            return true
        }
    }

    /// Puts the held events back at the head of the queue, in their order, for
    /// the list under the fingers.
    private func replayHeld() {
        let events = held
        held.removeAll(keepingCapacity: true)
        for event in events.reversed() {
            replayed.insert(event.timestamp)
            NSApp.postEvent(event, atStart: true)
        }
    }

    private func record(_ event: NSEvent, dx: CGFloat) {
        samples.append((event.timestamp, dx))
        // A tenth of a second is enough history for a release velocity.
        samples.removeAll { event.timestamp - $0.time > 0.1 }
    }

    /// Points per second over the last tenth of a second — zero for fingers
    /// that stopped before lifting.
    private func velocity(at time: TimeInterval) -> CGFloat {
        guard let first = samples.first, time - first.time > 0.008 else { return 0 }
        guard time - (samples.last?.time ?? time) < 0.05 else { return 0 }
        let distance = samples.reduce(0) { $0 + $1.dx }
        return distance / CGFloat(time - first.time)
    }
}
