import SwiftUI
import WingcordCore

/// Settings › Activity › Right now: everything this client is broadcasting,
/// drawn with the card everybody else sees (docs/CLIPS-PRESENCE.md, D22.1),
/// each with the switch that takes it off where there is one.
///
/// **Read from `publishedEntries`, the list the presence write itself sends** —
/// not from the reader's mirrored presence — so what this shows and what goes
/// out cannot drift apart.
struct BroadcastPreviewGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.publishedEntries
        SettingsGroup("Right now") {
            if entries.isEmpty {
                SettingsCard {
                    SettingsValueRow(
                        title: "Nothing is shared",
                        value: "—",
                        help: "A game, what\u{2019}s playing, an app or a presence you made appears here "
                            + "the way everyone else sees it."
                    )
                }
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    PreviewCard(entry: entry)
                }
            }
            SettingsFootnote(
                "Exactly what your friends and servers see right now.",
                symbolName: "eye"
            )
        }
    }
}

/// One published activity, its source, and what hides it.
private struct PreviewCard: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    var entry: AppModel.PublishedEntry

    var body: some View {
        SettingsCard {
            CurrentActivityCard(
                activity: Activity(published: entry.activity, sessionID: nil),
                buttonURLs: entry.activity.buttonURLs,
                ground: .neutral,
                openGame: nil,
                applicationIconURL: model.applicationIconURL(entry.activity.applicationID, side: 68),
                platesItself: false,
                isOwn: true
            )
            .padding(SettingsMetrics.cardContentInset)
            CardDivider()
            if let hide {
                SettingsActionRow(source, actionTitle: hide.title, action: hide.action)
            } else {
                SettingsValueRow(title: source, value: "")
            }
        }
    }

    private var source: String {
        switch entry.source {
        case .connectedApp: "Set by \(entry.activity.name) through Wingcord"
        case .customPresence: "A presence you made"
        case .game: "Detected on this Mac"
        case .embedded: "The activity you\u{2019}re in"
        case .nowPlaying: "Playing on this Mac"
        case .spotify: "From your Spotify connection"
        }
    }

    private var hide: (title: String, action: () -> Void)? {
        switch entry.source {
        case .connectedApp(let id?):
            return ("Block", { block(id) })
        case .customPresence:
            return ("Turn Off", { model.setCustomPresenceOn(nil) })
        case .nowPlaying:
            guard let player = model.sessionController.nowPlaying.player else { return nil }
            return ("Hide \(player.name)", {
                settings.nowPlayingPlayers[player.id] = false
                model.sessionController.nowPlayingSettingsChanged()
            })
        case .spotify:
            guard let connection = model.connections?.first(where: { $0.type == "spotify" && $0.showsActivity })
            else { return nil }
            return ("Hide", { model.sessionController.setConnectionShowsActivity(false, connection) })
        case .connectedApp(nil), .game, .embedded:
            return nil
        }
    }

    private func block(_ id: ApplicationID) {
        settings.blockedRPCApplications[String(id.rawValue)] = entry.activity.name
        model.reflectOwnPresenceNow()
        model.sessionController.publishPresence()
    }
}
