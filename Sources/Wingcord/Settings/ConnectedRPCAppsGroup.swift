import SwiftUI
import WingcordCore

/// Settings › Activity › Connected apps: the apps that set the reader's
/// activity through Wingcord's local RPC server — Music Presence, a game's
/// Discord SDK — each allowed or blocked (docs/CLIPS-PRESENCE.md, D22.4).
///
/// **A blocked app still connects**; its activity just never goes out. It is
/// remembered with the name it went by, so it stays listed — and can be let
/// back in — when it is not running.
struct ConnectedRPCAppsGroup: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    private struct App: Identifiable {
        var id: String
        var name: String
    }

    /// The apps sharing now, then the blocked ones that are not.
    private var apps: [App] {
        var seen = Set<String>()
        var list: [App] = []
        for activity in model.localRPCActivities.map(\.activity) {
            guard let id = activity.applicationID.map({ String($0.rawValue) }), seen.insert(id).inserted else { continue }
            list.append(App(id: id, name: activity.name))
        }
        for (id, name) in settings.blockedRPCApplications.sorted(by: { $0.value < $1.value })
        where seen.insert(id).inserted {
            list.append(App(id: id, name: name))
        }
        return list
    }

    var body: some View {
        SettingsGroup("Connected apps") {
            SettingsCard {
                if apps.isEmpty {
                    SettingsValueRow(
                        title: "None right now",
                        value: "—",
                        help: "An app that sets your activity through Wingcord appears here while it does."
                    )
                } else {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { CardDivider() }
                        SettingsToggle(
                            title: app.name,
                            help: "Lets \(app.name) set your activity.",
                            isOn: Binding(
                                get: { settings.blockedRPCApplications[app.id] == nil },
                                set: { allowed in setAllowed(allowed, app) }
                            )
                        )
                    }
                }
            }
            SettingsFootnote(
                "Apps like Music Presence, and games built with Discord\u{2019}s SDK, set your activity "
                    + "through Wingcord. A blocked app can still connect, but nothing it says is shared.",
                symbolName: "app.connected.to.app.below.fill"
            )
        }
    }

    private func setAllowed(_ allowed: Bool, _ app: App) {
        if allowed {
            settings.blockedRPCApplications[app.id] = nil
        } else {
            settings.blockedRPCApplications[app.id] = app.name
        }
        model.reflectOwnPresenceNow()
        model.sessionController.publishPresence()
    }
}
