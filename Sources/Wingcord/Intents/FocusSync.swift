import AppIntents
import Foundation
import Observation
import WingcordCore

// MARK: - A macOS Focus, worn as a Discord status
//
// The Focus filter (`WingcordFocusFilter`) is how the system tells Wingcord a
// Focus changed: its `perform()` runs as the Focus comes on with the values the
// reader chose for it, and again as the Focus goes off with the parameters'
// defaults — which here mean "nothing asked". `FocusPlan` decides what that
// means for the account; this applies it.
//
// **Three ways the call can come, and all three end up here.** While Wingcord
// runs, the filter's `perform()`. At launch, `checkAtLaunch()` asks the system
// for the filter as it stands, because a Focus may have come on or gone off
// while the app was not running. And on every READY, because READY hands back
// the account's stored status and would quietly undo a Focus mid-session.
//
// **The takeover is kept on disk.** The call that ends a Focus can arrive in a
// launch that never saw the one that began it — the custom status written then
// is still on the account, and putting it back needs to know what it replaced.

@Observable
@MainActor
final class FocusSync {

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let defaults: UserDefaults

    /// What the filter last asked for, as the reader chose it — kept raw so a
    /// change to "Wingcord's Focus status" in Settings reaches a Focus that is
    /// already on.
    @ObservationIgnored private var choice: (status: FocusStatusChoice, customStatusText: String?)?

    /// What a Focus is asking of the account right now. Nil until the filter
    /// has been heard from; empty once its Focus has ended.
    private(set) var request: FocusRequest?

    /// What a Focus has changed and the end of it must put back.
    @ObservationIgnored private var takeover: FocusTakeover? {
        didSet {
            guard takeover != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(takeover), forKey: Self.takeoverKey)
        }
    }

    private static let takeoverKey = "focus.takeover"

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        takeover = defaults.data(forKey: Self.takeoverKey)
            .flatMap { try? JSONDecoder().decode(FocusTakeover.self, from: $0) }
    }

    /// Whether a Focus is changing the reader's status at this moment.
    var isFocusActive: Bool { request.map { !$0.isEmpty } ?? false }

    // MARK: The three ways in

    /// The filter's call: a Focus came on, went off, or gave way to another.
    func filterChanged(_ status: FocusStatusChoice, customStatusText: String?) {
        choice = (status, customStatusText)
        request = Self.request(for: status, customStatusText: customStatusText, settings: AppSettings.shared)
        applyIfReady()
    }

    /// Asks the system what the filter says now.
    func checkAtLaunch() {
        Task { [weak self] in
            // **Throws when no Focus has the filter at all**, which is the same
            // answer as a Focus that is off: nothing asked.
            guard let filter = try? await WingcordFocusFilter.current else { return }
            self?.filterChanged(filter.status, customStatusText: filter.customStatus)
        }
    }

    /// READY has just written the account's stored status over whatever a
    /// Focus had set.
    func sessionDidBecomeReady() { applyIfReady() }

    /// "Wingcord's Focus status" changed in Settings while a Focus may be using it.
    func settingsChanged() {
        guard let choice, choice.status == .wingcord else { return }
        filterChanged(choice.status, customStatusText: choice.customStatusText)
    }

    // MARK: Applying

    private func applyIfReady() {
        guard let model, model.connectionState == .ready, let request else { return }
        let planned = request.isEmpty
            ? FocusPlan.end(
                currentStatus: model.selfStatus,
                currentCustomStatus: model.selfCustomStatus,
                existing: takeover,
                restores: AppSettings.shared.focusRestores
            )
            : FocusPlan.begin(
                request,
                currentStatus: model.selfStatus,
                currentCustomStatus: model.selfCustomStatus,
                existing: takeover
            )
        if let status = planned.status { model.updateSelfStatus(status) }
        if case .set(let custom) = planned.customStatus { model.updateSelfCustomStatus(custom) }
        takeover = planned.takeover
    }

    /// What a filter's two values ask of the account.
    ///
    /// **"Wingcord's Focus status" is the Settings pane's**, so the reader edits
    /// it in one place for every Focus that uses it. A custom-status text set on
    /// the filter itself wins over the one in Settings.
    static func request(
        for status: FocusStatusChoice,
        customStatusText: String?,
        settings: AppSettings
    ) -> FocusRequest {
        let text = customStatusText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownText = text.flatMap { $0.isEmpty ? nil : CustomStatus(text: String($0.prefix(CustomStatus.textLimit))) }
        switch status {
        case .unchanged: return FocusRequest(customStatus: ownText)
        case .wingcord: return FocusRequest(status: settings.focusStatus, customStatus: ownText ?? settings.focusCustomStatus)
        case .online: return FocusRequest(status: .online, customStatus: ownText)
        case .idle: return FocusRequest(status: .idle, customStatus: ownText)
        case .doNotDisturb: return FocusRequest(status: .doNotDisturb, customStatus: ownText)
        case .invisible: return FocusRequest(status: .invisible, customStatus: ownText)
        }
    }
}
