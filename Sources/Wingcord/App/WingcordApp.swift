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
                .showsPerformanceInspector()
                .presentsProfiles()
                .resolvesMotion()
                .environment(model)
                .frame(
                    minWidth: Proportions.windowMinWidth,
                    minHeight: Proportions.windowMinHeight
                )
        }
        .defaultSize(width: 1180, height: 760)
        .commands { WingcordCommands() }

        Settings {
            SettingsView()
                .environment(model)
                .resolvesMotion()
        }
    }
}

struct WingcordCommands: Commands {
    var body: some Commands {
        // The New Window and New Document items a default menu bar carries
        // point at scenes this app does not have.
        CommandGroup(replacing: .newItem) {}
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
