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
                    help: "Shows the emoji and the word someone chose for their typing indicator while "
                        + "they type alone — as Discord's phone apps do, and its desktop app doesn't yet.",
                    isOn: $settings.drawsCustomTypingIndicators
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
                "Previews change only this Mac. What Discord shows on its own apps is still Discord's to decide.",
                symbolName: "flask"
            )
        }
        // The transcript is drawn: a card whose look changed has to be told.
        .onChange(of: settings.voiceInviteCardStyle) { model.inviteSettlementChanged() }

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
                    ? "Plus \(unnamed) Discord doesn't name in its app — their names exist only on its servers."
                    : "Every experiment the account is in, as Discord's app names it.",
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
                "Worked out here exactly as Discord's app works it out, from the rollout it sent: the "
                    + "server's place in each, the populations that take it, and any override.",
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
                        "Discord's newer system names its experiments but not their variants, so a variant is its number.",
                        symbolName: "number"
                    )
                }
            }
        }
    }
}
