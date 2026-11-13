import AppKit
import Testing
@testable import Wingcord

/// Choosing Automatic with the desktop or a picture behind the window crashed
/// (2026-11-12): `apply` let go of the app's appearance and pinned one in the
/// same pass, each write woke the appearance observer synchronously, and the
/// observer ran `apply` again — until the main thread's stack ran out. Here the
/// same sequence has to settle.
@Suite("Theme appearance", .serialized)
struct ThemeAppearanceLoopTests {
    @Test("Automatic under a wallpaper's room settles, and lets go once the room is gone")
    func automaticWithARoomSettles() throws {
        let suite = "wingcord-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApplication.shared.appearance = nil
            ThemeRuntime.install(ThemeStore.shared.colors)
        }
        // The app's own store first, so it is not made — and does not let go
        // of the appearance in its first `apply` — halfway through the steps.
        // Two stores are a test's arrangement; the app has one.
        _ = ThemeStore.shared
        NSApplication.shared.appearance = nil
        let store = ThemeStore(defaults: defaults)
        #expect(store.choice == .system)

        store.setWallpaperRoom(.neutral)
        #expect(NSApplication.shared.appearance != nil, "a room holds the appearance it is drawn in")

        store.setWallpaperForcesDark(true)
        store.setWallpaperRoom(.theme)
        store.setWallpaperForcesDark(false)
        #expect(NSApplication.shared.appearance == nil, "Automatic with nothing behind the window is the system's")

        store.select(.preset(.porcelain))
        #expect(NSApplication.shared.appearance?.name == .aqua)
        store.select(.system)
        #expect(NSApplication.shared.appearance == nil)
    }
}
