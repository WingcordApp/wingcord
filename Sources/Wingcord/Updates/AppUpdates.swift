import AppKit
import Observation
import Sparkle
import WingcordCore

/// Updates: Sparkle underneath, Wingcord's own quiet signal on top
/// (docs/UPDATES.md D4, D6–D8).
///
/// **Only a release checks.** `scripts/release.sh` writes the feed into the
/// bundle, and a build without one never starts the updater — so the stable
/// copy can never replace itself with a release signed by another
/// certificate, which would cost it its Keychain access and its permissions.
///
/// **Nothing takes focus.** A scheduled check downloads in the background and
/// installs when Wingcord quits. An update that's ready puts Discord's green
/// arrow on the toolbar row (`UpdateToolbarButton`), and its card offers
/// Restart Now. Sparkle's own window is only behind Check for Updates…, for its
/// errors, and for a critical update while automatic installs are off.
@Observable
final class AppUpdates: NSObject {
    static let shared = AppUpdates()

    /// An update, as the arrow and its card describe it.
    struct Update: Equatable {
        /// "1.0 Beta 2".
        var displayVersion: String
        /// `CFBundleVersion`, which is the number Sparkle compares.
        var build: String
        /// What's new, in Markdown, from the appcast.
        var notes: String?
        var isCritical: Bool
    }

    enum State: Equatable {
        case idle
        /// Found by a scheduled check while automatic installs are off. The
        /// arrow brings Sparkle's window forward, which downloads it.
        case available(Update)
        /// Downloaded: it installs when Wingcord quits, or now.
        case ready(Update)
    }

    private(set) var state: State = .idle
    /// The card under the arrow is open.
    var isCardShown = false
    /// This build has a feed — it was made by the release command.
    private(set) var isEnabled = false
    private(set) var lastCheck: Date?
    /// Restart Now was pressed during a call, so the install waits for its end.
    private(set) var restartsAfterCall = false

    /// Download and install by themselves (D8). Sparkle keeps the setting;
    /// it's mirrored here so a switch can follow it.
    var installsAutomatically = true {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyDownloadsUpdates != installsAutomatically
            else { return }
            updater.automaticallyDownloadsUpdates = installsAutomatically
        }
    }

    /// Betas as well as releases (D7). On for anyone who has run a beta: the
    /// first launch of a prerelease writes it, so it outlasts the update to a
    /// release.
    var receivesBetas = false {
        didSet { UserDefaults.standard.set(receivesBetas, forKey: Self.betasKey) }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private let versionDisplay = UpdateVersionDisplay()

    private static let betasKey = "updates.receivesBetas"

    /// Starts the updater in a release; the demo's ready update with
    /// `--update-ready`. Call once, at launch.
    func start() {
        let defaults = UserDefaults.standard
        if Bundle.main.prerelease != nil, defaults.object(forKey: Self.betasKey) == nil {
            defaults.set(true, forKey: Self.betasKey)
        }
        receivesBetas = defaults.bool(forKey: Self.betasKey)

        if LaunchOptions.current.showsReadyUpdate {
            showDemoUpdate()
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        isEnabled = true
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        Log.info(.app, "updates: started, checking every \(Int(controller.updater.updateCheckInterval / 3600)) h")
    }

    /// Check for Updates…: Sparkle's window, which says what it found.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// The arrow: the card for an update that's ready, Sparkle's window for one
    /// that hasn't been downloaded.
    func arrowPressed() {
        switch state {
        case .idle: break
        case .available: checkForUpdates()
        case .ready: isCardShown.toggle()
        }
    }

    /// Restart Now: installs and relaunches — once the call is over, in one.
    func restart(model: AppModel) {
        guard case .ready = state, let installNow else { return }
        isCardShown = false
        guard model.connectedVoiceChannelID != nil else {
            installNow()
            return
        }
        restartsAfterCall = true
        waitForCallToEnd(model)
    }

    /// Takes back Restart Now's wait for the call to end.
    func cancelRestartAfterCall() {
        restartsAfterCall = false
    }

    private func waitForCallToEnd(_ model: AppModel) {
        withObservationTracking {
            _ = model.connectedVoiceChannelID
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model, self.restartsAfterCall else { return }
                guard model.connectedVoiceChannelID == nil else {
                    self.waitForCallToEnd(model)
                    return
                }
                // The leave sound plays out before the window goes.
                try? await Task.sleep(for: .seconds(2))
                guard self.restartsAfterCall, model.connectedVoiceChannelID == nil else { return }
                self.restartsAfterCall = false
                self.installNow?()
            }
        }
    }

    // MARK: The demo

    /// `--demo --update-ready`: the arrow and its card with sample notes, and
    /// no network. Restart Now quits and reopens the demo as an installed
    /// update would — without the flag, so it comes back with no arrow.
    private func showDemoUpdate() {
        isEnabled = true
        lastCheck = .now
        state = .ready(Update(displayVersion: "1.0 Beta 2", build: "2", notes: Self.demoNotes, isCritical: false))
        installNow = {
            Log.info(.demo, "updates: Restart Now, relaunching")
            AppRelaunch.afterQuitting(Bundle.main.bundleURL)
        }
    }

    private static let demoNotes = """
    ### New
    - Wingcord updates itself: a new version downloads in the background and installs when you quit.
    - **Settings ▸ About** shows what's new in the version you're running.

    ### Fixed
    - Joining a call with AirPods no longer crashes when they're muted.
    """
}

// MARK: - Sparkle's delegates

extension AppUpdates: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        receivesBetas ? ["beta"] : []
    }

    /// An update was downloaded by itself and waits for the quit. Taking it
    /// over (returning true) is what keeps Sparkle from putting up its own
    /// "ready to install" window later; the arrow says it instead.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installNow = immediateInstallHandler
        let update = Update(item)
        state = .ready(update)
        if update.isCritical { isCardShown = true }
        Log.info(.app, "updates: \(public: update.displayVersion) (\(public: update.build)) is ready")
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate
        guard let error = error as NSError?, error.code != Int(SUError.noUpdateError.rawValue) else { return }
        Log.fault(.app, "updates: check failed (\(public: error.domain) \(error.code))")
    }
}

extension AppUpdates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check never puts a window up — the arrow says it — unless
    /// the update is critical.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        update.isCriticalUpdate
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, case .idle = self.state else { return }
        self.state = .available(Update(update))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        if case .available = state { state = .idle }
    }

    func standardUserDriverWillFinishUpdateSession() {
        if case .available = state { state = .idle }
    }

    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        versionDisplay
    }
}

extension AppUpdates.Update {
    init(_ item: SUAppcastItem) {
        self.init(
            displayVersion: UpdateNaming.displayVersion(
                title: item.title,
                shortVersion: item.displayVersionString,
                build: item.versionString
            ),
            build: item.versionString,
            notes: UpdateNaming.notes(item.itemDescription, format: item.itemDescriptionFormat),
            isCritical: item.isCriticalUpdate
        )
    }
}

// MARK: - Relaunching

/// Quits, and opens `bundle` once this process has gone — so two copies never
/// run at once: they'd both want the same window, sockets and Keychain items.
/// Moving to Applications relaunches this way, and so does the demo's Restart
/// Now. (A real update's restart is Sparkle's own.)
enum AppRelaunch {
    static func afterQuitting(_ bundle: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        // The path travels as $0, never inside the script's text.
        waiter.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                            bundle.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Names

/// How an update is named, from what the appcast carries.
///
/// **The version stays numeric** — "1.0" — as Apple and Sparkle want it, so the
/// beta's name travels in the item's title, which the release command writes:
/// "Wingcord 1.0 Beta 2" (D3).
nonisolated enum UpdateNaming {
    static let titlePrefix = "Wingcord "

    /// "Wingcord 1.0 Beta 2" → "1.0 Beta 2". An item with another title says
    /// what Sparkle would: "1.0 (2)".
    static func displayVersion(title: String?, shortVersion: String, build: String) -> String {
        if let title, title.hasPrefix(titlePrefix) {
            let name = title.dropFirst(titlePrefix.count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "\(shortVersion) (\(build))"
    }

    /// The notes, when they're text the card can draw: Markdown or plain.
    /// Wingcord's appcasts carry Markdown; HTML, Sparkle's default, isn't
    /// drawn rather than drawn as tags.
    static func notes(_ description: String?, format: String?) -> String? {
        guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              format == "markdown" || format == "plain-text"
        else { return nil }
        return description
    }
}

/// Sparkle's own window, saying "1.0 Beta 2 is available — you have 1.0 Beta 1"
/// rather than "1.0 (2)" against "1.0 (1)".
nonisolated final class UpdateVersionDisplay: NSObject, SUVersionDisplay {
    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        inOutBundleDisplayVersion.pointee = Bundle.main.displayVersion as NSString
        return UpdateNaming.displayVersion(
            title: update.title,
            shortVersion: update.displayVersionString,
            build: update.versionString
        )
    }
}
