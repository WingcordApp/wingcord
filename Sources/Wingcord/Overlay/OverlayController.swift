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
    var notices: [OverlayNotice] = []

    /// The toast a reply is being typed into, and what is in it so far.
    ///
    /// **On the controller rather than in the toast's own `@State`**, because
    /// the auto-dismiss timer is here and the two are one fact: a toast with a
    /// half-typed reply in it is a toast that must not vanish. See
    /// `OverlayController.holdsNotice`.
    var replyingToNoticeID: UUID?
    var replyDraft = ""

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
        let wanted = settings.isOverlayEnabled && model?.detectedGame != nil
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

    private func applyInputState() {
        // **Nothing to configure when nothing is up.** `setLocked` is reachable
        // before the panel exists — the settings pane and the keybind both
        // change the lock — and reaching for a window that was never built is
        // work at best and, where it activates the app, a crash.
        guard isPresented else { return }
        // Locked, the panel is inert unless the reader has asked for clickable
        // regions — in which case the transparent ground still passes clicks
        // through and only the widgets take them. See `OverlayPanel`.
        let clickable = !isLocked || AppSettings.shared.overlayHasClickableRegions
        panel.setIgnoresMouseEvents(!clickable)
        if isLocked {
            panel.releaseKeyboardFocus()
        } else {
            panel.takeKeyboardFocus()
        }
        installEscapeMonitor()
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
        if isLocked {
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
                guard let self, self.isPresented, !self.isLocked else { return }
                self.setLocked(true)
                handled = true
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let peekMonitor { NSEvent.removeMonitor(peekMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        peekMonitor = nil
        escapeMonitor = nil
        isPeeking = false
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
