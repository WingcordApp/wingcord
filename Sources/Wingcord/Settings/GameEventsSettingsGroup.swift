import SwiftUI
import WingcordCore

/// Settings › Activity › Game events — the sources a clip's timeline reads
/// (docs/CLIPS-PRESENCE.md, D17 and D22.6).
///
/// Each Valve game is set up once, by writing its Game State Integration file
/// into the game's folder; League needs nothing; Steam Timeline says why it is
/// not read.
struct GameEventsSettingsGroup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsNavigate) private var navigate
    @State private var settings = AppSettings.shared
    @State private var failure: String?

    private var hub: GameEventHub { model.gameEvents }

    var body: some View {
        SettingsGroup("Game events in clips") {
            SettingsCard {
                valveRow("Dota 2", hub.dota, components: GameStateIntegration.dotaComponents)
                CardDivider()
                if hub.counterStrike.isEmpty {
                    SettingsValueRow(
                        title: "Counter-Strike 2",
                        value: "Not found",
                        help: "Read through CrossOver or Whisky, once it is installed in a bottle with Steam."
                    )
                } else {
                    ForEach(hub.counterStrike.keys.sorted(), id: \.self) { bottle in
                        if bottle != hub.counterStrike.keys.sorted().first { CardDivider() }
                        valveRow(
                            "Counter-Strike 2 — \(bottle)", hub.counterStrike[bottle] ?? .notFound,
                            components: GameStateIntegration.counterStrikeComponents
                        )
                    }
                }
                CardDivider()
                SettingsValueRow(
                    title: "League of Legends",
                    value: hub.isReadingLeague ? "Reading" : GameInstalls.leagueInstalled ? "Ready" : "Not installed",
                    help: "Read from League's own match API while a match runs. Nothing to set up."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Steam Timeline",
                    value: "Not read",
                    help: "Steam only keeps a timeline while its Game Recording is on, and there\u{2019}s none on this Mac."
                )
            }
            if let failure {
                SettingsFootnote("Couldn't set that up: \(failure)", symbolName: "exclamationmark.triangle")
            }
            SettingsFootnote(footnote, symbolName: "flag.pattern.checkered")
            // The same events choose Auto Clips (Phase 7.2) — the switch lives
            // with the rest of clips.
            SettingsCard {
                SettingsNavigationRow(
                    title: "Auto Clips",
                    subtitle: settings.autoClipsEnabled
                        ? "On — kills, wins and laughter keep themselves"
                        : "Off — let these events keep moments by themselves",
                    symbolName: "sparkles",
                    tint: SettingsSection.clips.tint
                ) { navigate(.clips) }
            }
        }
        .task { hub.discover() }
    }

    @ViewBuilder
    private func valveRow(_ title: String, _ setup: GameEventHub.Setup, components: [String]) -> some View {
        switch setup {
        case .notFound:
            SettingsValueRow(title: title, value: "Not installed", help: nil)
        case .found:
            SettingsActionRow(
                title,
                help: "Writes Valve's game state file into the game's folder. It takes effect the next time the game starts.",
                actionTitle: "Set Up…"
            ) {
                do {
                    try hub.setUp(setup, components: components)
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
            }
        case .ready:
            SettingsActionRow(
                title,
                help: "Set up. Kills, deaths and multi-kills go on your clips' timelines.",
                actionTitle: "Remove"
            ) {
                hub.remove(setup)
            }
        }
    }

    private var footnote: String {
        var text = "The game reports what happened \u{2014} Wingcord never reads the screen \u{2014} "
            + "while Clips is on."
        if !settings.clipsEnabled {
            text += " Turn on Clips to use them."
        } else if let last = hub.lastEvent {
            text += " Last: \(last.name)."
        }
        return text
    }
}
