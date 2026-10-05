import AppKit
import SwiftUI
import WingcordNet
import WingcordVoice

@main
struct WingcordApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(WingcordAppDelegate.self) private var appDelegate

    init() {
        // Installed before anything else can crash. The report file is opened
        // while the process is healthy precisely so the signal handler never has
        // to allocate.
        CrashReporter.install()
        // **And taken down again on a clean exit.** The report file is created
        // at launch so the signal handler never has to allocate, which means a
        // normal quit leaves a header-only file behind — indistinguishable from
        // a crash on the next launch. `finishCleanly` removes it, and without
        // this call every ordinary quit reported a crash that never happened.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in CrashReporter.finishCleanly() }
        // **Memory the app is holding for a window nobody is looking at.**
        // `PerformanceMonitor` already knows how to shed the large decoded
        // images twenty seconds after the window goes away, and to cancel that
        // the moment it comes back — it was simply never told when either
        // happened, so the shed never ran and a hidden window cost as much as a
        // visible one.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidHide() } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidHide() } }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidShow() } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidShow() } }
        if DiagnosticLog.isEnabled {
            GatewaySocket.traceSink = { message in
                DiagnosticLog.trace("gateway", message)
            }
            DiscordREST.traceSink = { message in
                DiagnosticLog.trace("rest", message)
            }
            // **The voice handshake is four steps, DAVE's is nine more, and
            // every way either fails is silent**, so the whole stack gets a
            // sink. Without this a call that never comes up produces exactly
            // as much evidence as one that does: none.
            VoiceTrace.sink = { message in
                DiagnosticLog.trace("voice", message)
            }
        }
        DiagnosticLog.trace("app", "launched")
        // The theme, before anything can paint with it.
        //
        // `Palette` would build this store lazily on its first read anyway, but
        // the first read is not guaranteed to be on the main thread — a drawn
        // canvas laying out a fixture would reach `ThemeRuntime` instead and get
        // the house palette, and the window would come up in True Black for one
        // frame before correcting itself.
        _ = ThemeStore.shared
        let model = AppModel()
        if LaunchOptions.current.usesDemoFixtures {
            DemoFixtures.populate(model)
        }
        if LaunchOptions.current.pretendsAGameIsRunning {
            DemoFixtures.populateDetectedGame(model)
        }
        _model = State(initialValue: model)
        PerformanceMonitor.shared.model = model
        WingcordAppDelegate.model = model
        MemoryPressureWatcher.shared.model = model
    }

    var body: some Scene {
        // A single `Window`, not a `WindowGroup`. A group restores every
        // previously opened window on the next launch, and this app owns one
        // workspace — a second copy of it would hold a second gateway
        // connection's worth of state.
        Window("Wingcord", id: "main") {
            // ORDER MATTERS, and getting it wrong is a launch crash rather
            // than a subtle defect. `.environment` supplies a value to the view
            // it is applied to and its DESCENDANTS — so a modifier attached
            // after it wraps that view and sits OUTSIDE the scope, where the
            // value it needs does not exist. Every modifier that reads the store
            // therefore goes above `.environment`, which stays outermost.
            RootView()
                // Above every ground, and above nothing else: the two columns
                // read their own place in this space to draw one picture across
                // both of them. See `ThemeGround.swift`.
                .backdropSpace()
                .mirrorsUnreadCountOnDock()
                .wearsServerThemes()
                .installsGlobalHotkey()
                .providesSettingsWindow()
                .providesServerSettingsWindow()
                .showsPerformanceInspector()
                .presentsMedia()
                .presentsMessageActions()
                .presentsProfiles()
                // **After the profiles, so it draws over them.** A game profile
                // is opened from a tile inside the full profile and has to sit
                // on top of the surface that raised it.
                .presentsGameProfile()
                // **After the game profile**, for the same reason it comes
                // after the profiles: a tenure badge is clicked on a badge row
                // that can be inside either of them.
                .presentsTenureBadge()
                .presentsSpotifyPlayer()
                .presentsUserMenu()
                .presentsDirectMessageMenu()
                .presentsServerOptions()
                .presentsChannelOptions()
                .presentsThreadOptions()
                .presentsCrosspostCards()
                .presentsAutoModCards()
                .presentsConversationHeads()
                .presentsActivityInfo()
                .presentsExpressionInfo()
                .presentsGuildSurfaces()
                .presentsJoinServer()
                .presentsSearchFilters()
                .presentsVoiceSurfaces()
                // **Last, so it draws over every one of them.** ⌘K is reached
                // from anywhere — including from on top of a profile card or a
                // game page — and a switcher that opened underneath the surface
                // it was summoned from would be invisible.
                .presentsQuickSwitcher()
                .watchesPushToTalk()
                .publishesGameActivity()
                .resolvesMotion()
                .environment(model)
                .frame(
                    minWidth: Proportions.windowMinWidth,
                    minHeight: Proportions.windowMinHeight
                )
        }
        .defaultSize(width: 1180, height: 760)
        .commands { WingcordCommands(model: model) }

        // An ordinary `Window`, not a `Settings` scene — see `SettingsWindow`
        // for why. It wears the settings scene's shortcut and menu item, which
        // `WingcordCommands` installs.
        Window("Settings", id: SettingsWindow.sceneID) {
            SettingsView()
                .resolvesMotion()
                .environment(model)
        }
        .defaultSize(
            width: SettingsMetrics.defaultWidth,
            height: SettingsMetrics.defaultHeight
        )
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        // The scene inherits no File menu of its own; the app has one workspace
        // and one settings window, and neither is a document.
        .commandsRemoved()

        // A server's own settings.
        //
        // **A `WindowGroup` here, where the two above are single `Window`s**,
        // and the difference is the point: this scene is *about* something. Two
        // servers' settings can be open at once — comparing two permission sets
        // is the most ordinary reason to want that — so the scene takes a value
        // and macOS keys a window per server off it.
        WindowGroup(id: ServerSettingsWindow.sceneID, for: ServerSettingsTarget.self) { target in
            if let value = target.wrappedValue {
                ServerSettingsView(target: value, model: model, controller: model.sessionController)
                    .resolvesMotion()
                    .environment(model)
            }
        }
        .defaultSize(
            width: SettingsMetrics.defaultWidth,
            height: SettingsMetrics.defaultHeight
        )
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}

struct WingcordCommands: Commands {
    /// The store, so the navigation items can act and can say when they cannot.
    ///
    /// Commands are built once per scene rather than per frame, and every item
    /// below reads a memoized projection — so an always-present menu costs a
    /// bounds check when it is opened and nothing at all when it is not.
    var model: AppModel

    var body: some Commands {
        // The New Window and New Document items a default menu bar carries
        // point at scenes this app does not have.
        CommandGroup(replacing: .newItem) {}
        // Settings is a `Window` scene rather than a `Settings` scene, so the
        // item and its ⌘, are installed by hand. Same title and same shortcut
        // macOS would have given it, in the same place in the app menu.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindow.open() }
                .keyboardShortcut(",", modifiers: .command)
        }

        // A Go menu rather than items buried in View: these are destinations, and
        // a reader looking for "how do I get to the next channel" looks under a
        // heading that says going somewhere.
        //
        // **Every equivalent here is read from `AppSettings`, not written
        // down.** That is what makes the shortcuts pane a set of bindings rather
        // than a printed table beside them: one list — `AppShortcut` — carries
        // the title, the default, the availability test and the verb, so a row
        // in the pane and an item in this menu cannot come to mean different
        // things.
        CommandMenu("Go") {
            Group {
                shortcutItem(.quickSwitcher)
                Divider()
                shortcutItem(.nextChannel)
                shortcutItem(.previousChannel)
                Divider()
                shortcutItem(.nextServer)
                shortcutItem(.previousServer)
                shortcutItem(.directMessages)

                Divider()

                // Nine items rather than a loop over the servers the reader
                // happens to have: ⌘4 must mean the fourth server whether or not
                // there is one, or the shortcut changes meaning as you join and
                // leave. **Deliberately not rebindable** — nine rows in a
                // settings pane for one idea, and the idea is the digit.
                ForEach(1...9, id: \.self) { ordinal in
                    Button("Server \(ordinal)") { model.selectGuild(atOrdinal: ordinal) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(ordinal)")), modifiers: .command
                        )
                }
                .disabled(!model.canNavigate)
            }
        }

        CommandMenu("Channel") {
            shortcutItem(.memberList)
            shortcutItem(.inbox)
            shortcutItem(.channelTopic)
            Divider()
            shortcutItem(.markChannelRead)
            shortcutItem(.markServerRead)
            Divider()
            shortcutItem(.toggleMute)
            shortcutItem(.toggleDeafen)
        }
    }

    /// One menu item, bound to whatever the reader has moved it to.
    ///
    /// **A cleared binding keeps its item and loses its equivalent**, which is
    /// what makes clearing one a way of freeing a combination rather than of
    /// hiding a command — the item is still in the menu, still says what it
    /// does, and is still clickable.
    ///
    /// On the item rather than on the menu: a whole menu that greys out while
    /// the app is connecting reads as a feature that is missing, where greyed
    /// items read as a feature that is not ready yet.
    @ViewBuilder
    private func shortcutItem(_ shortcut: AppShortcut) -> some View {
        let binding = AppSettings.shared.shortcut(for: shortcut)?.keyboardShortcut
        Button(shortcut.menuTitle) { shortcut.perform(in: model) }
            .keyboardShortcut(binding)
            .disabled(!shortcut.isAvailable(in: model))
    }
}

/// Launch arguments, read once.
///
/// Flags rather than a build configuration, so a release build can be driven
/// into a deterministic state for a screenshot or a benchmark without shipping
/// a second code path.
struct LaunchOptions: Sendable {
    var usesDemoFixtures = false
    /// Pretends a game is in front, so the overlay comes up without one.
    ///
    /// **The overlay could not be looked at at all before this.** Every widget
    /// on it is gated on `detectedGame != nil`, and there is no fixture for a
    /// running process — so the one surface in this app that is only ever drawn
    /// over somebody else's window had no way to be drawn over anything. It is
    /// its own flag rather than part of `--demo` because it takes the screen:
    /// the panel presents at shield level and covers the menu bar, which is
    /// right over a game and wrong over a desktop somebody is working on.
    var pretendsAGameIsRunning = false

    static let current: LaunchOptions = {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        return LaunchOptions(
            usesDemoFixtures: arguments.contains("--demo"),
            pretendsAGameIsRunning: arguments.contains("--overlay")
        )
    }()
}
