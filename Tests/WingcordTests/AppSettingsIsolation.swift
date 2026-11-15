import Testing
@testable import Wingcord

/// **The rule for app-wide settings in tests**: a test that changes
/// `AppSettings.shared`, or depends on one of its values, does it inside
/// `withAppSettings`, naming every setting it touches. `AppSettingsRuleTests`
/// checks that no test file writes to the settings any other way.
///
/// `AppSettings.shared` is one object for the whole test process, and Swift
/// Testing runs suites in parallel, so a setting one test changes is a setting
/// every other test sees until it's put back. Two failures on CI on 15 November
/// came from that: a settings test that turned bubbles on and off while the
/// canvas tests laid out rows, and canvas tests that assumed columns, which held
/// only because this Mac's test settings kept the last value written, while a
/// runner starts with none.
///
/// It saves the named settings, runs the body, and puts them back afterwards,
/// even when the body throws. Only one body runs at a time across the whole
/// test run, in the order they asked, so no other test that follows the rule
/// sees the values in between, even while a body waits or spins the run loop.
/// A body that calls it again is already inside, so the nested call doesn't
/// wait for itself.
@MainActor
func withAppSettings<each Value, Result>(
    _ keyPaths: repeat ReferenceWritableKeyPath<AppSettings, each Value>,
    perform body: (AppSettings) async throws -> Result
) async rethrows -> Result {
    let nested = AppSettingsTurn.isHeld
    if !nested { await AppSettingsTurn.shared.take() }
    defer { if !nested { AppSettingsTurn.shared.give() } }
    let settings = AppSettings.shared
    var restores: [() -> Void] = []
    for keyPath in repeat each keyPaths {
        restores.append(saving(keyPath, of: settings))
    }
    defer { for restore in restores.reversed() { restore() } }
    return try await AppSettingsTurn.$isHeld.withValue(true) {
        try await body(settings)
    }
}

@MainActor
private func saving<Value>(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>,
    of settings: AppSettings
) -> () -> Void {
    let saved = settings[keyPath: keyPath]
    return { settings[keyPath: keyPath] = saved }
}

/// The one `withAppSettings` body allowed to run, handed on first come, first
/// served.
@MainActor
final class AppSettingsTurn {
    static let shared = AppSettingsTurn()

    /// Whether the current task is inside a body already.
    @TaskLocal nonisolated static var isHeld = false

    private var isTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take() async {
        guard isTaken else {
            isTaken = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn straight to the next in line, or frees it.
    func give() {
        if waiting.isEmpty {
            isTaken = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
