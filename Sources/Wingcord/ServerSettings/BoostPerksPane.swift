import SwiftUI
import WingcordCore

// MARK: - Boost Perks
//
// Discord's Boost Perks page (`E8`): the progress bar, the banner over the
// channel list, the invite background, and — for an administrator — the
// Custom Invite Link. Every word is Discord's.
//
// **A perk the server has not reached wears Discord's "LVL" badge and offers
// nothing to press.** Discord's own button there opens a purchase flow this
// client does not have, and a button that opens nothing is the inert control
// `INVARIANTS.md` §5.5 forbids.

struct BoostPerksPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    var body: some View {
        LoadableContent(store.settings) { settings in
            VStack(alignment: .leading, spacing: 0) {
                progressBar(settings)
                banner(settings)
                inviteBackground(settings)
                if store.permissions.contains(.administrator) {
                    CustomInviteLinkSection(store: store, settings: settings)
                }
            }
        }
    }

    private func progressBar(_ settings: GuildSettings) -> some View {
        SettingsGroup {
            SettingsCard {
                DescribedRow(
                    "Show Boost progress bar",
                    detail: Text("Servers with the Boost progress bar enabled get more Boosts. This progress bar will display in your channel list, attached to your server name (or server banner if you have one set).")
                ) {
                    Toggle("Show Boost progress bar", isOn: Binding(
                        get: { settings.isPremiumProgressBarEnabled },
                        set: { isOn in Task { await store.saveBoostPerks(progressBar: isOn) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(SettingsSurface.switchOn)
                }
            }
        }
    }

    private func banner(_ settings: GuildSettings) -> some View {
        let isUnlocked = BoostTier.unlocks(.banner, features: settings.features, premiumTier: settings.premiumTier)
        return SettingsGroup {
            SettingsCard {
                DescribedRow(
                    "Server Banner Background",
                    detail: Text("This image will display at the top of your channels list.\nThe recommended minimum size is 960x540 and recommended aspect ratio is 16:9. [Learn more](https://support.discord.com/hc/en-us/articles/360028716472)."),
                    badge: isUnlocked ? nil : "LVL 2"
                ) {
                    EmptyView()
                }
                CardDivider()
                ImageWell(
                    title: settings.bannerHash == nil ? "Upload Background" : "Change Background",
                    detail: "",
                    url: settings.bannerHash.flatMap {
                        CDN.guildBanner(guildID: settings.id, hash: $0, width: 240)
                    },
                    isCircular: false,
                    allowsAnimated: BoostTier.unlocks(
                        .animatedBanner,
                        features: settings.features,
                        premiumTier: settings.premiumTier
                    ),
                    onPick: { image in Task { await store.saveBoostPerks(banner: .some(image)) } },
                    onRemove: settings.bannerHash == nil
                        ? nil
                        : { Task { await store.saveBoostPerks(banner: .some(nil)) } }
                )
                .disabled(!isUnlocked)
            }
        }
    }

    private func inviteBackground(_ settings: GuildSettings) -> some View {
        let isUnlocked = BoostTier.unlocks(.inviteSplash, features: settings.features, premiumTier: settings.premiumTier)
        return SettingsGroup {
            SettingsCard {
                DescribedRow(
                    "Server Invite Background",
                    detail: Text("This image will display when your server invite is viewed in a browser, as well as in invite confirmation screens and Server Onboarding."),
                    badge: isUnlocked ? nil : "LVL 1"
                ) {
                    EmptyView()
                }
                CardDivider()
                ImageWell(
                    title: settings.splashHash == nil ? "Upload Background" : "Change Background",
                    detail: "",
                    url: settings.splashHash.flatMap {
                        CDN.guildSplash(guildID: settings.id, hash: $0, width: 240)
                    },
                    isCircular: false,
                    allowsAnimated: false,
                    onPick: { image in Task { await store.saveBoostPerks(splash: .some(image)) } },
                    onRemove: settings.splashHash == nil
                        ? nil
                        : { Task { await store.saveBoostPerks(splash: .some(nil)) } }
                )
                .disabled(!isUnlocked)
            }
        }
    }
}

/// "Custom Invite Link": `discord.gg/` and the code, saved on Return, and
/// Remove Custom Invite Link.
private struct CustomInviteLinkSection: View {
    let store: ServerSettingsStore
    var settings: GuildSettings

    @State private var code = ""

    var body: some View {
        let isUnlocked = BoostTier.unlocks(.vanityURL, features: settings.features, premiumTier: settings.premiumTier)
        let current = store.vanity.value?.code ?? settings.vanityURLCode ?? ""
        SettingsGroup {
            SettingsCard {
                DescribedRow("Custom Invite Link", badge: isUnlocked ? nil : "LVL 3") {
                    EmptyView()
                }
                CardDivider()
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("Invite URL")
                        .font(SettingsType.rowTitle)
                        .foregroundStyle(Ink.primary)
                    HStack(spacing: 0) {
                        Text(verbatim: "discord.gg/")
                            .foregroundStyle(Ink.secondary)
                        TextField("", text: $code)
                            .textFieldStyle(.plain)
                            .onSubmit { save(code) }
                    }
                    .font(.system(.body))
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: Metrics.composerControlHeight)
                    .background(SettingsSurface.controlTrough, in: .settingsRect(8))
                    HStack(spacing: Spacing.snug) {
                        if code != current {
                            Button("Save Changes") { save(code) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        if !current.isEmpty {
                            Button("Remove Custom Invite Link", role: .destructive) { save("") }
                                .buttonStyle(.plain)
                                .font(.system(.caption))
                                .foregroundStyle(Palette.destructive)
                        }
                    }
                }
                .padding(SettingsMetrics.cardContentInset)
                .disabled(!isUnlocked)
            }
        }
        .onAppear { code = current }
        .onChange(of: current) { _, updated in code = updated }
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        Task { await store.saveVanityURL(trimmed) }
    }
}
