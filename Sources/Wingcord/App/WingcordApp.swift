import AppKit
import SwiftUI
import WingcordNet

@main
struct WingcordApp: App {
    @State private var model: AppModel

    init() {
        // Installed before anything else can crash. The report file is opened
        // while the process is healthy precisely so the signal handler never has
        // to allocate.
        CrashReporter.install()
        if DiagnosticLog.isEnabled {
            GatewaySocket.traceSink = { message in
                DiagnosticLog.trace("gateway", message)
            }
            DiscordREST.traceSink = { message in
                DiagnosticLog.trace("rest", message)
            }
        }
        DiagnosticLog.trace("app", "launched")
        let model = AppModel()
        if LaunchOptions.current.usesDemoFixtures {
            DemoFixtures.populate(model)
        }
        _model = State(initialValue: model)
        PerformanceMonitor.shared.model = model
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
                .mirrorsUnreadCountOnDock()
                .providesSettingsWindow()
                .showsPerformanceInspector()
                .presentsMedia()
                .presentsProfiles()
                .presentsExpressionInfo()
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
        CommandMenu("Go") {
            Group {
                Button("Next Channel") { model.stepChannel(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Previous Channel") { model.stepChannel(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)

            Divider()

            Button("Next Server") { model.stepGuild(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            Button("Previous Server") { model.stepGuild(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            Button("Direct Messages") { model.selectGuild(nil) }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            // Nine items rather than a loop over the servers the reader happens
            // to have: ⌘4 must mean the fourth server whether or not there is
            // one, or the shortcut changes meaning as you join and leave.
            ForEach(1...9, id: \.self) { ordinal in
                    Button("Server \(ordinal)") { model.selectGuild(atOrdinal: ordinal) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(ordinal)")), modifiers: .command
                    )
                }
            }
            // On the items rather than on the menu: a whole menu that greys out
            // while the app is connecting reads as a feature that is missing,
            // where greyed items read as a feature that is not ready yet.
            .disabled(!model.canNavigate)
        }
    }
}

/// Launch arguments, read once.
///
/// Flags rather than a build configuration, so a release build can be driven
/// into a deterministic state for a screenshot or a benchmark without shipping
/// a second code path.
struct LaunchOptions: Sendable {
    var usesDemoFixtures = false

    static let current: LaunchOptions = {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        return LaunchOptions(usesDemoFixtures: arguments.contains("--demo"))
    }()
}
