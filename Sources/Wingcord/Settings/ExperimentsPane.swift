import SwiftUI
import WingcordCore

/// Settings › Experiments: Wingcord's previews of what Discord is still
/// trying, then what Discord is trying on this account — read-only, as READY
/// gave it (docs/CLIPS-PRESENCE.md, D26).
///
/// **Nothing here changes an assignment.** Discord's overrides are a staff
/// tool kept in its own client; a reader who wants something Discord holds
/// back gets it from the previews above, which change only this Mac.
struct ExperimentsPane: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup("Wingcord previews") {
            SettingsCard {
                SettingsToggle(
                    title: "Custom typing indicators",
                    help: "Shows the emoji and word someone picked for their typing indicator, "
                        + "as Discord\u{2019}s phone apps do.",
                    isOn: $settings.drawsCustomTypingIndicators
                )
                CardDivider()
                SettingsToggle(
                    title: "Server Hub",
                    help: "Shows a server\u{2019}s Server Hub \u{2014} its banner, leaderboard, popular games, "
                        + "whiteboard and more \u{2014} where Discord has given the server one.",
                    isOn: $settings.showsServerHub
                )
                CardDivider()
                SettingsToggle(
                    title: "Games in Discover",
                    help: "Adds Discord\u{2019}s Games tab to Discover \u{2014} trending games, the ones you "
                        + "played, what your friends play, and game search \u{2014} before Discord turns it on "
                        + "for your account.",
                    isOn: $settings.showsGamesDiscovery
                )
                CardDivider()
                SettingsToggle(
                    title: "The Void",
                    help: "Adds Enter The Void to the Void badge in the Badge Directory. Orbs thrown into it are "
                        + "destroyed, and Discord still decides whether your account can throw any.",
                    isOn: $settings.showsOrbVoid
                )
                CardDivider()
                SettingsControlRow(
                    "Voice invites",
                    help: "Discord is trying a voice invite that looks like the channel in the sidebar."
                ) {
                    FlyoutPicker(
                        selection: $settings.voiceInviteCardStyle,
                        options: VoiceInviteCardStyle.allCases,
                        title: \.title,
                        detail: \.detail,
                        accessibilityTitle: "Voice invites"
                    )
                }
            }
            SettingsFootnote(
                "Previews change only this Mac.",
                symbolName: "flask"
            )
        }
        // The transcript is drawn: a card whose look changed has to be told.
        .onChange(of: settings.voiceInviteCardStyle) { model.inviteSettlementChanged() }
        // The channel list's row comes and goes with the switch.
        .onChange(of: settings.showsServerHub) { model.serverHubSwitchChanged() }

        if model.experiments.isEmpty {
            SettingsGroup("Discord's experiments") {
                SettingsCard {
                    SettingsValueRow(title: "Nothing yet", value: "—",
                                     help: "Discord sends these when Wingcord connects.")
                }
            }
        } else {
            userExperiments
            if let guildID = model.selectedGuildID, let guild = model.guilds[guildID] {
                serverExperiments(guildID, name: guild.name)
            }
            apexExperiments
        }
    }

    // MARK: The account's

    private var userExperiments: some View {
        let named = model.experiments.user.compactMap { assignment in
            KnownExperiments.byHash[assignment.hash].map { (assignment, $0) }
        }
        .sorted { $0.1.name > $1.1.name }
        let unnamed = model.experiments.user.count - named.count
        return SettingsGroup("Your account") {
            SettingsCard {
                if named.isEmpty {
                    SettingsValueRow(title: "None this build names", value: "—")
                }
                ForEach(Array(named.enumerated()), id: \.element.0.hash) { index, pair in
                    if index > 0 { CardDivider() }
                    SettingsValueRow(
                        title: pair.1.title,
                        value: ExperimentBucket.title(pair.0.bucket) + (pair.0.isOverride ? " · override" : ""),
                        help: pair.1.label == nil ? nil : pair.1.name
                    )
                }
            }
            SettingsFootnote(
                unnamed > 0
                    ? "Plus \(unnamed) that Discord\u{2019}s app doesn\u{2019}t name."
                    : "Every experiment your account is in, by Discord\u{2019}s names.",
                symbolName: "person.crop.circle"
            )
        }
    }

    // MARK: The open server's

    private func serverExperiments(_ guildID: GuildID, name: String) -> some View {
        // Newest first, as the account's are — the names open with their dates.
        let rows: [(KnownExperiment, Int)] = KnownExperiments.all
            .filter { $0.kind == .guild && !$0.isApex }
            .compactMap { known in model.guildExperimentBucket(known.name, in: guildID).map { (known, $0) } }
            .sorted { $0.0.name > $1.0.name }
        return SettingsGroup(name) {
            SettingsCard {
                if rows.isEmpty {
                    SettingsValueRow(title: "In none this build names", value: "—")
                }
                ForEach(Array(rows.enumerated()), id: \.element.0.name) { index, row in
                    if index > 0 { CardDivider() }
                    SettingsValueRow(title: row.0.title, value: ExperimentBucket.title(row.1), help: row.0.name)
                }
            }
            SettingsFootnote(
                "Worked out the way Discord\u{2019}s app does, from the rollout it sent.",
                symbolName: "server.rack"
            )
        }
    }

    // MARK: The newer system's

    private var apexExperiments: some View {
        let named = model.experiments.apex.compactMap { assignment in
            KnownExperiments.byHash[assignment.hash].map { (assignment, $0) }
        }
        .sorted { $0.1.name > $1.1.name }
        return Group {
            if !named.isEmpty {
                SettingsGroup("Newer experiments") {
                    SettingsCard {
                        ForEach(Array(named.enumerated()), id: \.offset) { index, pair in
                            if index > 0 { CardDivider() }
                            SettingsValueRow(
                                title: pair.1.name,
                                value: "Variant \(pair.0.variantID)" + (pair.0.isOverride ? " · override" : "")
                            )
                        }
                    }
                    SettingsFootnote(
                        "Discord doesn\u{2019}t name these variants, so each goes by its number.",
                        symbolName: "number"
                    )
                }
            }
        }
    }
}
