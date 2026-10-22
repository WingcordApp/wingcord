import AppKit
import Observation
import SwiftUI
import WingcordCore

// MARK: - The soundboard wheel
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D20). Discord's wheel (`026ef0ca9206d4ba.js`,
// `2026-05-global-soundboard-wheel-popout`): "Open the soundboard at your
// mouse's location anywhere." Two keys:
//
//   * **Open Soundboard (Hold)** — up while the key is held; letting go plays
//     the sound the pointer points at, or nothing from the middle.
//   * **Open Soundboard** — up until a sound is clicked, the key is pressed
//     again, or a click lands outside it.
//
// The sounds are Discord's choice: the ones this account may play in the
// call's server and Discord's own, favourites first; a page of eight, the
// scroll wheel turning pages.
//
// **The pointer is followed by its movement, not its position.** A game that
// has captured the mouse pins the cursor where it is, so its location never
// changes while the game turns; the deltas still arrive, and summing them is
// what lets a flick choose a sound over a game exactly as over the desktop.
// Mouse monitoring needs no permission; only the keyboard would.

@Observable
@MainActor
final class SoundboardWheelController {
    /// Whether the wheel is up.
    private(set) var isOpen = false
    /// Whether it closes when its key is let go.
    private(set) var isHolding = false
    /// The sounds, eight to a page.
    private(set) var pages: [[SoundboardPresentation.Entry]] = []
    private(set) var page = 0
    /// The place on this page the pointer points at.
    private(set) var focused: Int?
    /// How far the pointer has travelled from the middle, in points, y down —
    /// held inside the ring.
    private(set) var offset: CGVector = .zero

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let panel = SoundboardWheelPanel()
    @ObservationIgnored private var monitors: [Any] = []

    static let side = SoundboardWheelLayout.wheelSide

    func attach(_ model: AppModel) {
        self.model = model
    }

    // MARK: Opening and closing

    func open(holding: Bool) {
        // The toggle key closes a wheel it opened.
        if isOpen {
            if !holding { close() }
            return
        }
        guard let model, model.connectedVoiceChannelID != nil else {
            Breadcrumbs.record("soundboard wheel: not in a call")
            return
        }
        let presentation = model.soundboardPresentation
        // Discord's grid plays nothing while deafened, server-muted or
        // suppressed, and its wheel has nothing to offer then either.
        guard !presentation.isSilenced else {
            Breadcrumbs.record("soundboard wheel: silenced")
            return
        }
        model.soundboardDidOpen()
        let sounds = Self.sounds(in: presentation)
        guard !sounds.isEmpty else {
            Breadcrumbs.record("soundboard wheel: no sounds")
            return
        }
        pages = SoundboardWheelLayout.pages(of: sounds)
        page = 0
        focused = nil
        offset = .zero
        isHolding = holding
        isOpen = true
        panel.present(at: NSEvent.mouseLocation, side: Self.side, content: SoundboardWheelView(controller: self))
        installMonitors()
    }

    /// The hold key was let go: play what is pointed at, and close.
    func release() {
        guard isOpen, isHolding else { return }
        playFocused()
        close()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        panel.dismiss()
    }

    /// A click on a sound — the toggle wheel's way of choosing.
    func choose(_ slot: Int) {
        focused = slot
        playFocused()
        close()
    }

    private func playFocused() {
        guard let focused, pages.indices.contains(page), pages[page].indices.contains(focused) else { return }
        model?.pressSound(pages[page][focused].id)
    }

    // MARK: The pointer

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let handleMove: (NSEvent) -> Void = { [weak self] event in
            let delta = CGVector(dx: event.deltaX, dy: event.deltaY)
            MainActor.assumeIsolated { self?.moved(by: delta) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: handleMove) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { event in
            handleMove(event)
            return event
        }) {
            monitors.append(local)
        }
        // The scroll wheel turns pages — "Scroll for more".
        let handleScroll: (NSEvent) -> Void = { [weak self] event in
            let delta = event.scrollingDeltaY
            MainActor.assumeIsolated { self?.scrolled(delta) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handleScroll) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            handleScroll(event)
            return nil
        }) {
            monitors.append(local)
        }
        // A click anywhere but the wheel closes a wheel opened by its toggle;
        // a click on it is the wheel's own (`choose`).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHolding else { return }
                self.close()
            }
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func moved(by delta: CGVector) {
        guard isOpen else { return }
        // Held inside the ring: past it the bearing does not change, and an
        // offset that kept growing would take as long to come back.
        let limit = Self.side / 2
        var next = CGVector(dx: offset.dx + delta.dx, dy: offset.dy + delta.dy)
        let length = hypot(next.dx, next.dy)
        if length > limit {
            next = CGVector(dx: next.dx / length * limit, dy: next.dy / length * limit)
        }
        offset = next
        let count = pages.indices.contains(page) ? pages[page].count : 0
        let slot = SoundboardWheelLayout.slot(at: next, side: Self.side, count: count)
        if slot != focused { focused = slot }
    }

    @ObservationIgnored private var scrollCarry: CGFloat = 0

    private func scrolled(_ delta: CGFloat) {
        guard isOpen, pages.count > 1 else { return }
        scrollCarry += delta
        guard abs(scrollCarry) > 12 else { return }
        let next = page + (scrollCarry < 0 ? 1 : -1)
        scrollCarry = 0
        guard pages.indices.contains(next) else { return }
        page = next
        if let focused, focused >= pages[next].count { self.focused = nil }
    }

    // MARK: Which sounds

    /// Discord's list: favourites first, then the rest, from the servers the
    /// account may play in here and Discord's own — never one that is locked.
    static func sounds(in presentation: SoundboardPresentation) -> [SoundboardPresentation.Entry] {
        var seen: Set<String> = []
        var sounds: [SoundboardPresentation.Entry] = []
        let favourites = presentation.sections.filter { $0.kind == .favorites }.flatMap(\.sounds)
        let rest = presentation.sections
            .filter { $0.kind == .server || $0.kind == .defaults }
            .filter { !$0.isLocked }
            .flatMap(\.sounds)
        for sound in favourites + rest where !sound.isLocked {
            guard seen.insert(sound.id).inserted else { continue }
            sounds.append(sound)
        }
        return sounds
    }
}

// MARK: - Its window

/// A small borderless panel at the pointer, above everything — a game
/// included — that never takes Wingcord to the front.
@MainActor
final class SoundboardWheelPanel {
    private var panel: NSPanel?

    func present(at point: CGPoint, side: CGFloat, content: some View) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        var frame = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        // Kept whole on the display the pointer is on.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let bounds = screen.frame
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - side)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - side)
        }
        panel.setFrame(frame, display: false)
        let hosting = WheelHostingView(rootView: AnyView(content))
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        // Out of screen capture with the rest of Wingcord while Streamer Mode
        // asks.
        panel.sharingType = StreamerMode.shared.settings.hidesWindowsFromCaptureNow ? .none : .readOnly
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

/// Takes the first click: the wheel is over somebody else's app, and a click
/// on a sound must play it rather than only bring the panel forward.
private final class WheelHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
