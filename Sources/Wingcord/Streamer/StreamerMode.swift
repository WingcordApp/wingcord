import AppKit
import Observation
import WingcordCore

// MARK: - Streamer Mode, on this Mac
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D21). The settings are Discord's
// (`StreamerModeSettings`, Core); this is where they take effect:
//
//   * personal information — the account's email and phone, notes on
//     profiles, the reader's connected accounts — is withheld where it is
//     drawn (`hidesPersonalInformation`);
//   * invite codes are drawn as dots, and copying still copies the real link
//     ("Streamer mode is active, invite codes are hidden");
//   * the call's sounds and the banners' sound stop (`VoiceSoundPlayer`,
//     `SessionController.announce`);
//   * banners stop (`SessionController.announce`);
//   * every window is left out of screen capture — `NSWindow.sharingType =
//     .none`, which ScreenCaptureKit honours on macOS 27 (measured: a `.none`
//     window is absent from an `SCScreenshotManager` capture of its display,
//     a `.readOnly` one present). OBS captures through ScreenCaptureKit, so
//     this reaches it. The overlay is a window too, so the reader still sees
//     it over the game and the stream does not;
//   * chosen overlay widgets are withheld (`OverlayLayout.visibleWidgets`).
//
// The streaming software is watched with `NSWorkspace`'s launch and terminate
// notifications — nothing polls.

@Observable
@MainActor
final class StreamerMode {
    static let shared = StreamerMode()

    /// Discord's settings, as the reader left them.
    private(set) var settings: StreamerModeSettings

    /// The streaming software running right now, by name.
    private(set) var runningSoftware: [String] = []

    var isEnabled: Bool { settings.isEnabled }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "streamerMode.settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(StreamerModeSettings.self, from: $0) }
            ?? StreamerModeSettings()
    }

    // MARK: Changing it

    func toggle() {
        setEnabled(!settings.isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        update { $0.isEnabled = enabled }
    }

    func update(_ change: (inout StreamerModeSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let wasEnabled = settings.isEnabled
        settings = next
        persist()
        if wasEnabled != next.isEnabled {
            Breadcrumbs.record("streamer mode: \(next.isEnabled ? "on" : "off")")
        }
        apply()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // MARK: Watching for the software

    /// Starts watching for streaming software and applies the current state.
    /// Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescan() }
            })
        }
        // Windows that appear later are covered as they come on screen — a
        // popover, a sheet, the media viewer, the overlay itself.
        let windows = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            windowObservers.append(windows.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let number = (note.object as? NSWindow)?.windowNumber
                MainActor.assumeIsolated {
                    guard let self, let number,
                          let window = NSApp?.windows.first(where: { $0.windowNumber == number })
                    else { return }
                    self.protect(window)
                }
            })
        }
        rescan()
        apply()
    }

    /// Re-reads what is running. Cheap: a walk of the regular applications.
    private func rescan() {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            StreamingSoftware.match(bundleIdentifier: app.bundleIdentifier, name: app.localizedName)?.name
        }
        let names = Array(Set(running)).sorted()
        let changed = (names.isEmpty) != runningSoftware.isEmpty
        runningSoftware = names
        guard changed else { return }
        var next = settings
        if next.streamingSoftwareChanged(running: !names.isEmpty) {
            update { $0 = next }
        }
    }

    // MARK: What it does

    /// Puts every effect in step with the settings.
    private func apply() {
        for window in NSApp?.windows ?? [] { protect(window) }
        // Masks and gates are read where they are drawn; this is the one
        // place a drawn canvas learns that its words changed.
        PresentationRevision.shared.settingsDidChange()
    }

    /// Leaves `window` out of screen capture while asked to, and puts it back.
    private func protect(_ window: NSWindow) {
        let wanted: NSWindow.SharingType = settings.hidesWindowsFromCaptureNow ? .none : .readOnly
        guard window.sharingType != wanted else { return }
        window.sharingType = wanted
    }

    // MARK: What the surfaces ask

    var hidesPersonalInformation: Bool { settings.hidesPersonalInformationNow }
    var hidesInviteLinks: Bool { settings.hidesInviteLinksNow }
    var disablesSounds: Bool { settings.disablesSoundsNow }
    var disablesNotifications: Bool { settings.disablesNotificationsNow }
    var hiddenOverlayWidgets: Set<OverlayWidgetKind> { settings.hiddenOverlayWidgetsNow }

    /// An invite link as it should be drawn right now.
    func inviteText(_ link: String) -> String {
        hidesInviteLinks ? StreamerModeMask.invite(link) : link
    }

    /// A bare invite code as it should be drawn right now.
    func inviteCode(_ code: String) -> String {
        hidesInviteLinks ? StreamerModeMask.code(code) : code
    }

    /// Discord's words under a hidden invite.
    static let inviteNotice = "Streamer mode is active, invite codes are hidden"
}
