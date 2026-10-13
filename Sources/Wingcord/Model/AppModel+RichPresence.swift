import Foundation
import WingcordCore

// MARK: - The Rich Presence builder
//
// Alex's idea (DESIGN-NOTES §11): presences made in the full profile's Activity
// tab, in edit mode, each card editable where it sits. Vencord's CustomRPC is
// the model — its fields, its rules and the activity it sends — and one card is
// on at a time, replacing the detected game while it is.

extension AppModel {

    /// Every card, in the reader's order.
    var customPresences: [CustomPresence] { AppSettings.shared.customPresences }

    /// The card that is on.
    var activeCustomPresence: CustomPresence? {
        let settings = AppSettings.shared
        guard let id = settings.activeCustomPresenceID else { return nil }
        return settings.customPresences.first { $0.id == id }
    }

    /// The card that is on, as the activity it publishes — nil while none is
    /// on, or while it breaks one of Vencord's rules.
    var customPresenceActivity: RichPresenceActivity? {
        guard let presence = activeCustomPresence else { return nil }
        let prefix = presence.applicationID + " "
        var assets: [String: String] = [:]
        for (key, id) in customPresenceAssets where key.hasPrefix(prefix) {
            assets[String(key.dropFirst(prefix.count))] = id
        }
        return presence.activity(assets: assets, turnedOnAt: customPresenceTurnedOnAt, now: .now)
    }

    /// A new, empty card at the end — the builder's "+".
    @discardableResult
    func addCustomPresence() -> CustomPresence.ID {
        let presence = CustomPresence()
        AppSettings.shared.customPresences.append(presence)
        return presence.id
    }

    /// One card's edit, as it is typed. A card that is on goes out again once
    /// the typing stops.
    func updateCustomPresence(_ presence: CustomPresence) {
        let settings = AppSettings.shared
        guard let index = settings.customPresences.firstIndex(where: { $0.id == presence.id }),
              settings.customPresences[index] != presence else { return }
        settings.customPresences[index] = presence
        if settings.activeCustomPresenceID == presence.id { customPresenceChanged() }
    }

    func removeCustomPresence(_ id: CustomPresence.ID) {
        let settings = AppSettings.shared
        if settings.activeCustomPresenceID == id { setCustomPresenceOn(nil) }
        settings.customPresences.removeAll { $0.id == id }
    }

    /// Turns one card on — and every other off — or all of them off.
    func setCustomPresenceOn(_ id: CustomPresence.ID?) {
        let settings = AppSettings.shared
        guard settings.activeCustomPresenceID != id else { return }
        settings.activeCustomPresenceID = id
        // "Since discord open": the clock starts when it goes on.
        customPresenceTurnedOnAt = .now
        customPresenceChanged(immediately: true)
    }

    /// Vencord's "Show Custom RPC": the card last on, or the first.
    var showsCustomPresence: Bool { AppSettings.shared.activeCustomPresenceID != nil }

    func toggleShowsCustomPresence() {
        let settings = AppSettings.shared
        if settings.activeCustomPresenceID != nil {
            setCustomPresenceOn(nil)
        } else if let id = settings.lastCustomPresenceID.flatMap({ last in
            settings.customPresences.first { $0.id == last }?.id
        }) ?? settings.customPresences.first?.id {
            setCustomPresenceOn(id)
        }
    }

    /// Resolves the card's pictures and publishes it — after a beat while it is
    /// being typed, so a sentence is one presence update rather than one per
    /// letter (Vencord debounces its writes the same way).
    func customPresenceChanged(immediately: Bool = false) {
        customPresenceWrite?.cancel()
        customPresenceWrite = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            if let presence = activeCustomPresence {
                await sessionController.resolveCustomPresenceAssets(of: presence)
            }
            guard !Task.isCancelled else { return }
            reflectOwnPresenceNow()
            sessionController.publishPresence()
        }
    }
}
