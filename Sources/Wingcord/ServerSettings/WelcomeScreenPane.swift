import SwiftUI
import WingcordCore

// MARK: - Welcome Screen
//
// Discord's page as it stands now (`1e901507`'s `cJ`): frozen, with a notice
// that says so and sends the reader to Onboarding. What it still allows is
// what this allows — Disable, Preview, and taking a channel out or moving one.
// The description is shown and not editable; no channel can be added. Every
// word is Discord's.

struct WelcomeScreenPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var isPreviewing = false
    @State private var removing: Removal?

    /// A channel on its way out, waiting on Discord's question.
    private struct Removal: Identifiable {
        var index: Int
        var channelName: String?
        var id: Int { index }
    }

    var body: some View {
        LoadableContent(store.welcomeScreen) { screen in
            VStack(alignment: .leading, spacing: 0) {
                notice
                SettingsGroup {
                    Text("If enabled, this Welcome Screen appears for new members when they join your server. This screen helps new members discover all the cool things they can do in your server!")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Spacing.snug)
                    statusCard(screen)
                }
                greeting(screen)
                channels(screen)
            }
            .sheet(isPresented: $isPreviewing) {
                WelcomeScreenSheet(
                    presentation: model.welcomeScreenPresentation(
                        for: store.guildID,
                        screen: screen
                    ),
                    openChannel: { model.openWelcomeScreenChannel($0) }
                )
            }
            .sheet(item: $removing) { removal in
                FormSheet(
                    title: "Remove Recommended Channel",
                    confirmTitle: "Remove",
                    isDestructive: true,
                    closesOnConfirm: true,
                    confirm: {
                        var channels = screen.channels
                        guard channels.indices.contains(removal.index) else { return }
                        channels.remove(at: removal.index)
                        Task { await store.saveWelcomeChannels(channels) }
                    }
                ) {
                    Group {
                        if let name = removal.channelName {
                            Text("Are you sure you want to remove \(Text(verbatim: "#\(name)").bold()) from recommended channels?")
                        } else {
                            Text("Are you sure you want to remove this channel from recommended channels?")
                        }
                    }
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: The notice

    /// "Changes to the Welcome Screen are disabled", with Discord's link to
    /// Onboarding inside the sentence.
    private var notice: some View {
        SettingsGroup {
            SettingsCard {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Ink.secondary)
                        .accessibilityHidden(true)
                    Text("Changes to the Welcome Screen are disabled. The Welcome Screen will still appear for your members. A new and improved version of Welcome Screen is now available through [Onboarding](wingcord-settings:onboarding), and will replace Welcome Screen if enabled.")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.primary)
                        .tint(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.openURL, OpenURLAction { _ in
                            ServerSettingsWindow.open(store.guildID, section: .onboarding)
                            return .handled
                        })
                }
                .padding(SettingsMetrics.cardContentInset)
            }
        }
    }

    // MARK: Status

    /// Discord's status card (`cY`): a tick or a pencil, two lines, Preview,
    /// and the switch — which is drawn as Enable and cannot be pressed once
    /// the screen is off, because turning it back on is a change, and changes
    /// are what Discord froze.
    private func statusCard(_ screen: WelcomeScreen) -> some View {
        let isEnabled = store.isWelcomeScreenEnabled
        return SettingsCard {
            DescribedRow(
                isEnabled ? "Your Welcome Screen is up and running." : "Your changes are saved automatically.",
                detail: Text(isEnabled
                    ? "New members will be greeted by this screen when they join!"
                    : "Don't forget to enable when you're finished!")
            ) {
                Image(symbol: isEnabled ? "checkmark" : "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(Palette.affirmative) : AnyShapeStyle(Ink.secondary))
                    .frame(width: 32, height: 32)
                    .background(SettingsSurface.controlTrough, in: .circle)
                    .accessibilityHidden(true)
            } trailing: {
                HStack(spacing: Spacing.snug) {
                    // Nothing to preview without a channel in it.
                    if !screen.isEmpty {
                        Button("Preview") { isPreviewing = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if isEnabled {
                        Button("Disable", role: .destructive) {
                            Task { await store.disableWelcomeScreen() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.destructive)
                        .controlSize(.small)
                    } else {
                        Button("Enable") {}
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(true)
                    }
                }
            }
        }
    }

    // MARK: The greeting

    /// The top of the screen as new members see it: the server, and its
    /// description — shown in Discord's field, which it no longer lets anybody
    /// type in.
    private func greeting(_ screen: WelcomeScreen) -> some View {
        let guild = model.guilds[store.guildID]
        let name = guild?.name ?? ""
        return SettingsGroup {
            SettingsCard {
                VStack(spacing: Spacing.snug) {
                    GuildAvatar(
                        url: guild?.iconHash.flatMap { CDN.guildIcon(guildID: store.guildID, hash: $0, side: 64) },
                        name: name,
                        side: 64
                    )
                    Text("Welcome to \(Text(verbatim: name).bold())")
                        .font(.system(.title2, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .multilineTextAlignment(.center)
                    Group {
                        if let description = screen.description {
                            Text(verbatim: description)
                                .foregroundStyle(Ink.secondary)
                        } else {
                            Text("What's this server about? What do people do here?")
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                    .font(SettingsType.rowSubtitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.snug)
                    .background(SettingsSurface.controlTrough, in: .settingsRect(8))
                }
                .frame(maxWidth: .infinity)
                .padding(SettingsMetrics.cardContentInset)
            }
        }
    }

    // MARK: Top things to do

    private func channels(_ screen: WelcomeScreen) -> some View {
        SettingsGroup("Top things to do") {
            Text("Select up to 5 recommended channels. We suggest channels where people can interact, like channels for discussions, asking questions, reading news, or selecting roles.")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.snug)
            SettingsCard {
                ForEach(Array(screen.channels.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { CardDivider() }
                    channelRow(entry, at: index, in: screen)
                }
            }
        }
    }

    /// One recommended channel (`cq`): its emoji or the channel's glyph — a
    /// warning in place of both where `@everyone` cannot see it — the words,
    /// the channel, and Remove Channel. Move Up and Move Down are its
    /// right-click, as they are Discord's.
    private func channelRow(_ entry: WelcomeScreen.Channel, at index: Int, in screen: WelcomeScreen) -> some View {
        let channel = store.channels.first { $0.id == entry.channelID }
        let isVisible = channel?.isPublic == true
        let emoji = entry.emoji(among: model.guildEmojis[store.guildID] ?? [])
        return DescribedRow(
            entry.description,
            detail: isVisible
                ? Text("\(Image(symbol: channel?.kind.symbolName ?? "number")) \(channel?.name ?? "")")
                : Text("This channel is no longer in Welcome Screen because it does not exist or is not viewable by @everyone")
                    .foregroundStyle(Palette.destructive)
        ) {
            Group {
                if !isVisible {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.destructive)
                } else if let emoji {
                    ExpressionGlyph(emoji: emoji, side: 24)
                } else {
                    Image(symbol: channel?.kind.symbolName ?? "number")
                        .foregroundStyle(Ink.secondary)
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 32, height: 32)
        } trailing: {
            RowIconButton(symbolName: "trash", label: "Remove Channel", role: .destructive) {
                removing = Removal(index: index, channelName: channel?.name)
            }
        }
        .contextMenu {
            Button("Move Up") { move(index, by: -1, in: screen) }
                .disabled(index == 0)
            Button("Move Down") { move(index, by: 1, in: screen) }
                .disabled(index >= screen.channels.count - 1)
            Divider()
            Button("Remove Channel", role: .destructive) {
                removing = Removal(index: index, channelName: channel?.name)
            }
        }
    }

    /// Discord saves a move the moment it lands, and so does this.
    private func move(_ index: Int, by offset: Int, in screen: WelcomeScreen) {
        var channels = screen.channels
        let target = index + offset
        guard channels.indices.contains(index), channels.indices.contains(target) else { return }
        channels.swapAt(index, target)
        Task { await store.saveWelcomeChannels(channels) }
    }
}
