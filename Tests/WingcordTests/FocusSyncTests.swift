import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A macOS Focus, worn as a status: what the filter's two values ask for, and
/// the model following a Focus on and off.
@Suite("Focus sync")
@MainActor
struct FocusSyncTests {

    private func settings(_ name: String = #function) -> AppSettings {
        let defaults = UserDefaults(suiteName: "FocusSyncTests.\(name)")!
        defaults.removePersistentDomain(forName: "FocusSyncTests.\(name)")
        return AppSettings(defaults: defaults)
    }

    @Test("'Don't change' with no text asks nothing — the call that ends a Focus")
    func unchangedIsEmpty() {
        let request = FocusSync.request(for: .unchanged, customStatusText: nil, settings: settings())
        #expect(request.isEmpty)
        let blank = FocusSync.request(for: .unchanged, customStatusText: "   ", settings: settings())
        #expect(blank.isEmpty)
    }

    @Test("'Wingcord's Focus status' is the Settings pane's status and custom status")
    func wingcordChoiceReadsSettings() {
        let settings = settings()
        settings.focusStatus = .idle
        settings.focusCustomStatus = CustomStatus(text: "Heads down", emoji: EmojiRef(name: "🎧"))
        let request = FocusSync.request(for: .wingcord, customStatusText: nil, settings: settings)
        #expect(request.status == .idle)
        #expect(request.customStatus?.text == "Heads down")
        #expect(request.customStatus?.emoji?.name == "🎧")
    }

    @Test("Text written on the filter wins over the one in Settings")
    func filterTextWins() {
        let settings = settings()
        settings.focusCustomStatus = CustomStatus(text: "Heads down")
        let request = FocusSync.request(for: .wingcord, customStatusText: " In a match ", settings: settings)
        #expect(request.customStatus?.text == "In a match")
        let own = FocusSync.request(for: .unchanged, customStatusText: "Gaming", settings: settings)
        #expect(own.status == nil)
        #expect(own.customStatus?.text == "Gaming")
    }

    @Test("A filter's own status is taken as it is")
    func explicitStatus() {
        let request = FocusSync.request(for: .invisible, customStatusText: nil, settings: settings())
        #expect(request == FocusRequest(status: .invisible))
    }

    @Test("The Focus settings survive a relaunch")
    func settingsPersist() {
        let defaults = UserDefaults(suiteName: "FocusSyncTests.persist")!
        defaults.removePersistentDomain(forName: "FocusSyncTests.persist")
        let first = AppSettings(defaults: defaults)
        first.focusStatus = .invisible
        first.focusCustomStatus = CustomStatus(text: "Away", emoji: EmojiRef(name: "🌙"))
        first.focusRestores = false
        let second = AppSettings(defaults: defaults)
        #expect(second.focusStatus == .invisible)
        #expect(second.focusCustomStatus == CustomStatus(text: "Away", emoji: EmojiRef(name: "🌙")))
        #expect(second.focusRestores == false)
    }

    @Test("A Focus coming on sets the status, and its end puts the old one back")
    func followsFocusOnAndOff() {
        let model = AppModel()
        model.connectionState = .ready
        model.selfStatus = .online
        let defaults = UserDefaults(suiteName: "FocusSyncTests.cycle")!
        defaults.removePersistentDomain(forName: "FocusSyncTests.cycle")
        let sync = FocusSync(model: model, defaults: defaults)

        sync.filterChanged(.doNotDisturb, customStatusText: nil)
        #expect(model.selfStatus == .doNotDisturb)
        #expect(sync.isFocusActive)

        sync.filterChanged(.unchanged, customStatusText: nil)
        #expect(model.selfStatus == .online)
        #expect(!sync.isFocusActive)
    }

    @Test("A call that arrives before the session waits for READY")
    func waitsForReady() {
        let model = AppModel()
        model.connectionState = .connecting
        model.selfStatus = .online
        let defaults = UserDefaults(suiteName: "FocusSyncTests.ready")!
        defaults.removePersistentDomain(forName: "FocusSyncTests.ready")
        let sync = FocusSync(model: model, defaults: defaults)

        sync.filterChanged(.doNotDisturb, customStatusText: nil)
        #expect(model.selfStatus == .online)

        model.connectionState = .ready
        sync.sessionDidBecomeReady()
        #expect(model.selfStatus == .doNotDisturb)
    }
}
