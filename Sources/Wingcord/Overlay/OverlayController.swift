import AppKit
import Observation
import SwiftUI
import WingcordCore

// MARK: - The overlay's state machine
//
// **Two states and one boolean**, which is the model Discord's own overlay
// turned out to be built on — `isInputLocked(pid)`, read out of the bundle:
//
//                  locked (passive)          unlocked (open)
//   widgets        pinned only               all
//   interactive    no                        yes
//   ground         nothing                   a scrim
//   chrome         an unlock button          close, and the keybind that closed it
//
// Everything else follows. `OverlayLayout.visibleWidgets(locked:)` is the whole
// of the first row; `OverlayPanel.setIgnoresMouseEvents` is the second.
//
// Four things put it back to sleep, and one of them is the ground itself:
//
//   1. the keybind,
//   2. Escape,
//   3. a click on the background — not on a widget, which is the distinction
//      that makes "click outside to dismiss" work at all,
//   4. the game going away.

@Observable
@MainActor
final class OverlayController {

    /// Whether the overlay window is on screen at all.
    ///
    /// **Not the same as unlocked.** A game running with the voice panel pinned
    /// has the overlay present and locked: visible, click-through, showing one
    /// widget. Presented is about the window existing; locked is about who owns
    /// the mouse.
    private(set) var isPresented = false

    /// Whether the game has the mouse.
    ///
    /// Starts locked. An overlay that opened unlocked would steal the pointer
    /// from a game the moment somebody launched it.
    private(set) var isLocked = true

    /// Whether the reader is rearranging widgets.
    ///
    /// Only reachable from the unlocked state, and locking leaves it.
    private(set) var isEditingLayout = false

    /// Suppresses every widget while held, so the reader can see the game.
    ///
    /// **Discord binds this to Alt, and it HIDES rather than reveals** — which
    /// is the opposite of what the layout-mode screenshots suggest and was
    /// worth reading the dispatch to be sure of.
    private(set) var isPeeking = false

    /// Where the widgets are.
    var layout: OverlayLayout {
        didSet {
            guard layout != oldValue else { return }
            OverlayLayoutStore.save(layout)
        }
    }

    /// Arrangements the reader kept, beside the built-in presets. Phase 6.
    private(set) var savedLayouts: [OverlaySavedLayout] = OverlayLayoutStore.loadSaved() {
        didSet { OverlayLayoutStore.saveSaved(savedLayouts) }
    }

    /// The built-in preset the current layout is, if it is one.
    var currentPreset: OverlayLayoutPreset? { OverlayLayoutPreset.matching(layout) }

    /// The saved layout the current one is, if it is one.
    var currentSavedLayout: OverlaySavedLayout? {
        savedLayouts.first { $0.layout.isEquivalent(to: layout) }
    }

    func apply(_ preset: OverlayLayoutPreset) {
        layout = preset.layout
    }

    func apply(_ saved: OverlaySavedLayout) {
        layout = saved.layout
    }

    /// Keeps the current arrangement under the next free name. Refused at the
    /// limit, and when it is already kept.
    func saveCurrentLayout() {
        guard savedLayouts.count < OverlaySavedLayout.limit, currentSavedLayout == nil else { return }
        savedLayouts.append(
            OverlaySavedLayout(name: OverlaySavedLayout.nextName(after: savedLayouts), layout: layout)
        )
    }

    func renameSavedLayout(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedLayouts.firstIndex(where: { $0.id == id }) else { return }
        savedLayouts[index].name = String(trimmed.prefix(40))
    }

    func deleteSavedLayout(_ id: UUID) {
        savedLayouts.removeAll { $0.id == id }
    }

    /// Which of the sidebar's three lists is showing.
    ///
    /// **Persisted.** Reopening the overlay onto a tab the reader did not choose
    /// is the surface forgetting something it watched them do, and the overlay
    /// is dismissed and rebuilt every time a game quits.
    var sidebarTab: OverlaySidebarTab = OverlayLayoutStore.loadSidebarTab() {
        didSet {
            guard sidebarTab != oldValue else { return }
            // **The query does not survive the tab.** "cyn" typed to find a
            // friend filters the voice list to nothing, and an empty list under
            // a field somebody has stopped looking at reads as there being no
            // rooms rather than as a filter still being on.
            sidebarQuery = ""
            OverlayLayoutStore.saveSidebarTab(sidebarTab)
        }
    }

    /// What the sidebar's field is narrowing by. Not persisted: a query is a
    /// thing somebody is doing, not a thing they chose.
    var sidebarQuery = ""

    /// Conversations open as chat windows. **The first is the one drawn**; the
    /// rest are the faces on the rail beside it.
    ///
    /// Written only by `OverlayController+Chat`, which is where every rule about
    /// the order lives — `private(set)` would be the honest spelling and Swift
    /// scopes it to this *file*, so it would lock that extension out of the one
    /// property it exists to maintain.
    var chatChannelIDs: [ChannelID] = []

    /// Toasts on screen right now. See `OverlayNotice`.
    ///
    /// Their presence decides whether a sleeping overlay takes clicks at all —
    /// see `applyInputState` — so the panel is re-configured whenever the queue
    /// moves.
    var notices: [OverlayNotice] = [] {
        didSet {
            guard notices.isEmpty != oldValue.isEmpty else { return }
            applyInputState()
        }
    }

    /// The toast a reply is being typed into, and what is in it so far.
    ///
    /// **On the controller rather than in the toast's own `@State`**, because
    /// the auto-dismiss timer is here and the two are one fact: a toast with a
    /// half-typed reply in it is a toast that must not vanish. See
    /// `OverlayController.holdsNotice`.
    var replyingToNoticeID: UUID? {
        didSet {
            guard (replyingToNoticeID != nil) != (oldValue != nil) else { return }
            // Typing needs the keyboard, and a sleeping overlay has released it
            // — see `applyInputState`.
            applyInputState()
        }
    }
    var replyDraft = ""

    /// Whether a reply field is open on a toast.
    var isReplying: Bool { replyingToNoticeID != nil }

    /// What the clip key just did, if anything.
    var clipFeedback: ClipFeedback?
    /// Which `showClipFeedback` call owns the current message, so a later one
    /// cannot be cleared by an earlier one's timer.
    var clipFeedbackToken: UUID?

    /// The last thing that went wrong, for the settings pane to show.
    private(set) var lastFailure: String?

    /// The LIVE row the pointer is resting on, and where that row is.
    ///
    /// **Raised at the scene's root rather than by the row** — §2's rule about
    /// presentation modifiers in a list, and the only way the card can hang
    /// outside the voice widget without that widget growing to contain it.
    private(set) var streamHover: OverlayStreamHover?

    /// Cameras the reader has switched OFF in the video widget.
    ///
    /// **An exclusion rather than a selection**, and that is what makes the
    /// default right: a video widget that starts empty reads as broken, so
    /// "shown" is the absence of an entry. It also decides the decode — an
    /// unchecked tile installs no sink at all — so it is a fact about cost as
    /// well as about layout. See `OverlayVideoTilesWidget`.
    private(set) var hiddenVideoUserIDs: Set<UserID> = []

    /// Toasts whose lifetime ran out while a reply was open on them.
    /// See `OverlayController.releaseNoticeHold`.
    var expiredNoticeIDs: Set<UUID> = []

    private let panel = OverlayPanel()
    private var peekMonitor: Any?
    private var escapeMonitor: Any?
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?

    // MARK: Click zones
    //
    // **Per-pixel pass-through is not a property a window has.** A window that
    // takes mouse events takes all of them, transparent pixels included — so an
    // overlay left non-ignoring while a game is in front makes the whole screen
    // unclickable. The only way to have both is to move `ignoresMouseEvents` as
    // the pointer moves, which is what Discord's own V3 overlay calls *click
    // zones*, and what this is.
    //
    // `@ObservationIgnored` throughout: these are written by the view layer on
    // every layout and read by an event monitor, never by a body. Publishing
    // them would invalidate the scene that wrote them, on every frame of a
    // drag.

    /// Where each widget is, in the overlay's own space.
    @ObservationIgnored private var widgetZones: [OverlayWidgetKind: CGRect] = [:]
    /// Where the corner's controls are — the unlock button while locked.
    @ObservationIgnored private var chromeZone: CGRect = .zero
    /// Whether the pointer is currently over something that should take a click.
    @ObservationIgnored private var isPointerOverZone = false
    /// Whether the reader's own profile has been asked for this run.
    private var hasRequestedIdentity = false
    private weak var model: AppModel?

    init(model: AppModel? = nil) {
        self.model = model
        layout = OverlayLayoutStore.load()
    }

    func attach(model: AppModel) {
        self.model = model
    }

    /// Asks for the reader's own profile, once.
    ///
    /// **The banner and the theme colours live ONLY on
    /// `GET /users/{id}/profile`** — the user objects on READY and on the
    /// member-list op carry neither — and every existing caller of that route is
    /// somebody opening *somebody else's* card. So the one account whose
    /// cosmetics this client had never fetched was the reader's own, and the
    /// sidebar is the first surface that wants them.
    ///
    /// Asked once per run rather than per appearance: the answer cannot change
    /// without the reader editing their profile, and the overlay is presented
    /// and dismissed every time a game starts and stops. The derivation for an
    /// account that set no colours rides on the same answer — `loadProfile`
    /// finishes by calling `deriveTheme`, which is gated on Nitro full rather
    /// than on having paid at all (`PremiumTier.derivesProfileTheme`: Basic is a
    /// paid tier that Discord leaves grey).
    func prepareIdentity() {
        guard !hasRequestedIdentity, let model, let userID = model.currentUserID else { return }
        hasRequestedIdentity = true
        model.sessionController.loadProfile(of: userID, inGuild: nil)
    }

    // MARK: What decides whether it is up at all

    /// Re-evaluates presence from the world: is a game running, and is the
    /// overlay switched on.
    ///
    /// Called whenever the detected game or the preference changes. Idempotent,
    /// so callers do not have to know whether anything actually moved.
    func refreshPresentation() {
        let settings = AppSettings.shared
        // Registered Games' "Toggle overlay" — Discord's "Overlay is disabled
        // for this game."
        let gameAllows = model?.detectedGame.map {
            RegisteredGamesStore.shared.games.showsOverlay($0.id.rawValue)
        } ?? false
        let wanted = settings.isOverlayEnabled && gameAllows
        if wanted {
            present()
        } else {
            dismiss()
        }
    }

    private func present() {
        guard let model else { return }
        guard let screen = NSScreen.main else { return }
        isPresented = true
        panel.present(
            on: screen,
            // The shield covers the menu bar, which is right over a game and
            // wrong over anything else. A detected game is the licence.
            level: model.detectedGame != nil ? .aboveCapturedDisplay : .ordinary,
            content: OverlayScene(controller: self).environment(model)
        )
        applyInputState()
        installPeekMonitor()
        installPointerMonitor()
    }

    private func dismiss() {
        guard isPresented else { return }
        isPresented = false
        isEditingLayout = false
        isLocked = true
        clearTransientState()
        removeMonitors()
        panel.dismiss()
    }

    func tearDown() {
        removeMonitors()
        panel.tearDown()
        isPresented = false
        isLocked = true
        isEditingLayout = false
        clearTransientState()
    }

    /// Everything that belongs to *this* appearance of the overlay.
    ///
    /// **Open chats survive the lock and not the dismissal.** Locking is the
    /// reader going back to the game with the same conversations waiting;
    /// dismissal is the game quitting, and a chat window left open across two
    /// different sessions of two different games is a surface remembering
    /// something nobody asked it to. A half-typed reply is cleared for the
    /// stronger version of the same reason — it belongs to a toast that is gone.
    /// The pointer came to rest on somebody's LIVE row.
    func hoverStream(_ userID: UserID, anchor: CGRect) {
        guard anchor != .zero else { return }
        // A `@State`-shaped write of an equal value still invalidates, and this
        // one invalidates the whole scene — §2.
        guard streamHover?.userID != userID || streamHover?.anchor != anchor else { return }
        streamHover = OverlayStreamHover(userID: userID, anchor: anchor)
    }

    /// The pointer left a row.
    ///
    /// **Only clears the card that row opened.** Sweeping down a roster fires
    /// the leave for one row after the enter for the next, so an unconditional
    /// clear would close the card that had just opened.
    func endStreamHover(_ userID: UserID) {
        guard streamHover?.userID == userID else { return }
        streamHover = nil
    }

    func toggleVideoTile(_ userID: UserID) {
        if hiddenVideoUserIDs.contains(userID) {
            hiddenVideoUserIDs.remove(userID)
        } else {
            hiddenVideoUserIDs.insert(userID)
        }
    }

    private func clearTransientState() {
        chatChannelIDs = []
        hiddenVideoUserIDs = []
        streamHover = nil
        notices = []
        replyingToNoticeID = nil
        replyDraft = ""
        sidebarQuery = ""
    }

    // MARK: The lock

    /// The overlay keybind. Opens it, or puts it back to sleep.
    ///
    /// **Presents on demand even with no game running.** A reader who bound a
    /// key and pressed it expects something to happen; refusing silently
    /// because no game was detected is the single most confusing thing this
    /// surface could do.
    func toggle() {
        if !isPresented {
            AppSettings.shared.isOverlayEnabled = true
            present()
            setLocked(false)
            return
        }
        setLocked(!isLocked)
    }

    /// The second keybind: hand the mouse back without dismissing.
    func toggleInputLock() {
        guard isPresented else { return }
        setLocked(!isLocked)
    }

    func setLocked(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
        if locked { isEditingLayout = false }
        applyInputState()
    }

    /// A click that landed on the ground rather than on a widget.
    ///
    /// The test lives in the view — a `.background` that only the ground hosts —
    /// because SwiftUI cannot tell us what a click passed over, only what it
    /// reached.
    func backgroundClicked() {
        setLocked(true)
    }

    /// Puts every widget back where it started.
    ///
    /// **The reference has one (`resetDefaultLayout`) and this did not**, which
    /// matters more here than there: a widget dragged off the edge of a display
    /// that is no longer attached is clamped back into view on the next resolve,
    /// but a layout somebody has made a mess of over a game has no other way
    /// out — the only control that could fix it is the arrange mode they would
    /// have to find first.
    func resetLayout() {
        layout = .default
    }

    func setEditingLayout(_ editing: Bool) {
        // **The lock is the precondition, not the window.** Whether a panel
        // exists is the panel's business; arranging widgets is about who owns
        // the mouse. `dismiss()` clears this, so it cannot survive the overlay
        // going away.
        guard !isLocked else { return }
        isEditingLayout = editing
    }

    // MARK: Plumbing the state into the window

    /// Whether a widget may take a click in the state the overlay is in.
    ///
    /// **The locked state is the game's**, so only the toast is an exception —
    /// and only while the reader has not asked for the broader behaviour. See
    /// `applyInputState`.
    func acceptsHits(_ kind: OverlayWidgetKind) -> Bool {
        guard isLocked else { return true }
        if AppSettings.shared.overlayHasClickableRegions { return true }
        // The toast is the exception, and it is not a preference: it is the one
        // widget whose entire purpose is to be answered *while playing*, it is
        // transient, and the panel is a `.nonactivatingPanel` — so taking that
        // click does not pull Wingcord in front of the game.
        return kind == .notifications
    }

    private func applyInputState() {
        // **Nothing to configure when nothing is up.** `setLocked` is reachable
        // before the panel exists — the settings pane and the keybind both
        // change the lock — and reaching for a window that was never built is
        // work at best and, where it activates the app, a crash.
        guard isPresented else { return }
        // Locked, the panel is inert **except while the pointer is over a click
        // zone** — see `pointerMoved`, which is the only other writer of this.
        // The latch is reset here so a lock taken while the pointer was over
        // the toast does not leave the panel taking the whole screen.
        isPointerOverZone = false
        let clickable = !isLocked || AppSettings.shared.overlayHasClickableRegions
        // **A window that takes mouse events takes ALL of them**, and that is
        // the fact this line exists to respect.
        //
        // Making the panel non-ignoring while locked was tried and reverted
        // inside one session: the reasoning was that the window server
        // hit-tests rendered alpha, so a transparent ground would pass clicks
        // to the game. It does not. The hosting view spans the whole panel and
        // answers the hit test wherever it is asked, `Color.clear` and
        // `allowsHitTesting(false)` included — so an overlay left non-ignoring
        // makes **the entire screen** unclickable, which is the one failure
        // this surface may never have.
        //
        // Per-pixel pass-through is not a property a window has. It is a thing
        // a client does by moving `ignoresMouseEvents` as the pointer moves,
        // which is what Discord's own V3 overlay calls *click zones* — see
        // `OverlayClickZones`.
        panel.setIgnoresMouseEvents(!clickable)
        // **Replying takes the keyboard without unlocking**, which is the whole
        // shape of answering a notification mid-game: the toast expands in
        // place, the scrim never appears, the other widgets stay away, and the
        // game keeps the screen. Unlocking to type a line would dim everything
        // and draw eight widgets over a match.
        if isLocked, !isReplying {
            panel.releaseKeyboardFocus()
        } else {
            panel.takeKeyboardFocus()
        }
        installEscapeMonitor()
        // **Recomputed from where the pointer actually is**, rather than left
        // for the next move. A click that changes the state — opening a reply
        // on a toast — would otherwise hand the mouse back mid-interaction and
        // the second click on the same control would go to the game.
        pointerMoved()
    }

    // MARK: Alt to peek, Escape to leave

    private func installPeekMonitor() {
        guard peekMonitor == nil else { return }
        // A **local** monitor: this fires only while Wingcord has key focus,
        // which is exactly when the overlay is unlocked and peeking means
        // anything. A global one would need the accessibility permission to
        // watch every modifier press on the machine, for a convenience.
        peekMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            let held = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated {
                guard let self, self.isPresented, !self.isLocked else { return }
                if self.isPeeking != held { self.isPeeking = held }
            }
            return event
        }
    }

    private func installEscapeMonitor() {
        if isLocked, !isReplying {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            return
        }
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // 53 is Escape. Swallowed rather than passed on: the overlay is in
            // front and the key belongs to it.
            guard event.keyCode == 53 else { return event }
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                // **The reply first, and only then the overlay.** Escape out of
                // a half-typed line is the reader abandoning that line, not
                // asking for the whole surface to go away — and while a toast is
                // being replied to on a sleeping overlay there is no surface to
                // put away in the first place.
                if self.isReplying {
                    let id = self.replyingToNoticeID
                    self.cancelReply()
                    if let id { self.releaseNoticeHold(id) }
                    handled = true
                    return
                }
                guard !self.isLocked else { return }
                self.setLocked(true)
                handled = true
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let peekMonitor { NSEvent.removeMonitor(peekMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        peekMonitor = nil
        escapeMonitor = nil
        pointerMonitor = nil
        localPointerMonitor = nil
        isPeeking = false
        isPointerOverZone = false
        widgetZones = [:]
        chromeZone = .zero
    }

    // MARK: The zones

    func setClickZone(_ rect: CGRect, for kind: OverlayWidgetKind) {
        guard widgetZones[kind] != rect else { return }
        widgetZones[kind] = rect
        pointerMoved()
    }

    func clearClickZone(for kind: OverlayWidgetKind) {
        guard widgetZones.removeValue(forKey: kind) != nil else { return }
        pointerMoved()
    }

    func setChromeZone(_ rect: CGRect) {
        guard chromeZone != rect else { return }
        chromeZone = rect
        pointerMoved()
    }

    /// A **global** monitor, because the pointer is over the game and the panel
    /// is ignoring events — so there is nothing local to hear.
    ///
    /// Mouse monitoring needs no accessibility permission; only keyboard does.
    /// The work per event is a handful of rect containments and an early return
    /// whenever the answer has not changed, which is every event but the two
    /// that cross a boundary.
    private func installPointerMonitor() {
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        }
        // **And a local one, because a global monitor never sees this app's own
        // events.** Over a game Wingcord is not frontmost and the global
        // monitor is the whole story; with the workspace window in front it
        // sees nothing at all, and without this pair the zones would work over
        // a game and not over the desktop — which is exactly the state anybody
        // testing the overlay is in.
        if localPointerMonitor == nil {
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: kinds) {
                [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            }
        }
    }

    /// Hands the panel the mouse exactly while the pointer is over something
    /// that would answer a click, and gives it straight back.
    private func pointerMoved() {
        guard isPresented else { return }
        // Unlocked, the whole surface is the reader's and the scrim is the
        // point. Nothing to track.
        guard isLocked else { return }
        let inside = isPointerOverZone(at: NSEvent.mouseLocation)
        guard inside != isPointerOverZone else { return }
        isPointerOverZone = inside
        panel.setIgnoresMouseEvents(!inside)
    }

    /// - Parameter location: screen coordinates, bottom-left origin.
    private func isPointerOverZone(at location: CGPoint) -> Bool {
        let frame = panel.frameInScreen
        guard frame.width > 0, frame.height > 0, frame.contains(location) else { return false }
        // The overlay's own space is top-left origin, which is what every
        // `onGeometryChange` in the scene reports in.
        let point = CGPoint(
            x: location.x - frame.minX,
            y: frame.maxY - location.y
        )
        if chromeZone.contains(point) { return true }
        for (kind, rect) in widgetZones where acceptsHits(kind) {
            if rect.contains(point) { return true }
        }
        return false
    }

    func report(_ failure: String) {
        lastFailure = failure
        Breadcrumbs.record("overlay: \(failure)")
    }
}

// MARK: - The layout, between launches

enum OverlayLayoutStore {
    private static let key = "overlay.layout"
    private static let tabKey = "overlay.sidebarTab"
    private static let savedKey = "overlay.savedLayouts"

    static func loadSaved() -> [OverlaySavedLayout] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode([OverlaySavedLayout].self, from: data)
        else { return [] }
        return saved
    }

    static func saveSaved(_ saved: [OverlaySavedLayout]) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    static func load() -> OverlayLayout {
        guard let data = UserDefaults.standard.data(forKey: key),
              let layout = try? JSONDecoder().decode(OverlayLayout.self, from: data)
        else { return .default }
        return layout
    }

    static func save(_ layout: OverlayLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Stored by **name**, so reordering the enum cannot silently change which
    /// list a returning reader lands on — the rule the rest of `AppSettings`
    /// already follows.
    static func loadSidebarTab() -> OverlaySidebarTab {
        UserDefaults.standard.string(forKey: tabKey)
            .flatMap(OverlaySidebarTab.init(rawValue:)) ?? .friends
    }

    static func saveSidebarTab(_ tab: OverlaySidebarTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: tabKey)
    }
}
