import SwiftUI
import WingcordCore

// MARK: - Server Profile
//
// **One route serves this page and the next one**, and every save sends the
// whole thing — see `DiscordREST.updateGuildProfile` and the captures behind it.
// That decides the shape of both panes: each edits a local copy of the profile
// and hands the *whole* copy back, so there is no arrangement of controls that
// can send a subset.
//
// The local copy is why `draft` exists rather than binding straight at the
// store: a text field bound to the store would write on every keystroke, and
// every write here is a network round trip that replaces eight fields.

struct ServerProfilePane: View {
    let store: ServerSettingsStore

    /// The edited copy. Nil until the fetch lands.
    @State private var draft: GuildProfile?
    @State private var games: [GameSummary] = []
    @State private var isPickingGames = false

    var body: some View {
        LoadableContent(store.profile) { profile in
            let binding = draftBinding(profile)
            VStack(alignment: .leading, spacing: 0) {
                identity(binding, committed: profile)
                banner(binding)
                traits(binding)
                description(binding, committed: profile)
                gamesSection(binding)
                privacy(binding)
            }
            .task(id: profile.id) { adopt(profile) }
            .task(id: profile.gameApplicationIDs) { await resolveGames(profile) }
        }
    }

    // MARK: Sections

    private func identity(
        _ profile: Binding<GuildProfile>,
        committed: GuildProfile
    ) -> some View {
        SettingsGroup("Identity") {
            SettingsCard {
                EditableTextRow(
                    title: "Name",
                    placeholder: "Server name",
                    text: profile.name,
                    committed: committed.name
                ) {
                    save(profile.wrappedValue)
                }
                CardDivider()
                ImageWell(
                    title: "Icon",
                    detail: "At least 512×512.",
                    url: iconURL(profile.wrappedValue),
                    isCircular: true,
                    onPick: { image in save(profile.wrappedValue, icon: .some(image)) },
                    onRemove: profile.wrappedValue.iconHash == nil
                        ? nil
                        : { save(profile.wrappedValue, icon: .some(nil)) }
                )
            }
        }
    }

    /// The swatch grid.
    ///
    /// **This is `brand_color_primary`, and it is the control Discord labels
    /// "Banner".** The capture is unambiguous: choosing the pink tile sent
    /// `"brand_color_primary": "#ff1c90"` and nothing else changed. The uploaded
    /// artwork behind a tag is a different field, and the boost banner is a
    /// third — see `GuildProfile.brandColorPrimary`, where the three are told
    /// apart once.
    private func banner(_ profile: Binding<GuildProfile>) -> some View {
        SettingsGroup("Banner") {
            SettingsCard {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: Spacing.base),
                            count: 4
                        ),
                        spacing: Spacing.base
                    ) {
                        ForEach(BrandColor.swatches, id: \.self) { value in
                            BrandSwatch(
                                value: value,
                                isSelected: profile.wrappedValue.brandColorPrimary == value
                            ) {
                                var next = profile.wrappedValue
                                next.brandColorPrimary = value
                                save(next)
                            }
                        }
                    }
                }
                .padding(SettingsMetrics.cardContentInset)
            }
            SettingsFootnote(
                "Shown behind your server's name in invite links and, if you are "
                    + "in Server Discovery, on your listing."
            )
        }
    }

    private func traits(_ profile: Binding<GuildProfile>) -> some View {
        SettingsGroup("Traits") {
            SettingsCard {
                TraitEditor(traits: profile.traits) { save(profile.wrappedValue) }
            }
            SettingsFootnote(
                "Up to \(GuildTraitLimits.maximum) words describing your server's "
                    + "interests and personality."
            )
        }
    }

    private func description(
        _ profile: Binding<GuildProfile>,
        committed: GuildProfile
    ) -> some View {
        SettingsGroup("Description") {
            SettingsCard {
                EditableTextBlock(
                    placeholder: "How did your server get started? Why should people join?",
                    text: Binding(
                        get: { profile.wrappedValue.description ?? "" },
                        set: { profile.wrappedValue.description = $0.isEmpty ? nil : $0 }
                    ),
                    committed: committed.description ?? "",
                    characterLimit: 300
                ) {
                    save(profile.wrappedValue)
                }
            }
        }
    }

    private func gamesSection(_ profile: Binding<GuildProfile>) -> some View {
        SettingsGroup("Games") {
            SettingsCard {
                if games.isEmpty {
                    Text("This server has not named any games.")
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(Ink.secondary)
                        .padding(SettingsMetrics.cardContentInset)
                } else {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: Spacing.snug),
                            count: 4
                        ),
                        spacing: Spacing.snug
                    ) {
                        ForEach(games) { game in
                            GameTile(game: game) {
                                var next = profile.wrappedValue
                                next.gameApplicationIDs.removeAll { $0 == game.id }
                                save(next)
                            }
                        }
                    }
                    .padding(SettingsMetrics.cardContentInset)
                }
                CardDivider()
                SettingsActionRow(
                    "Add a game",
                    actionTitle: "Search…"
                ) {
                    isPickingGames = true
                }
            }
        }
        .sheet(isPresented: $isPickingGames) {
            GamePickerSheet(
                store: store,
                chosen: Set(profile.wrappedValue.gameApplicationIDs)
            ) { game in
                var next = profile.wrappedValue
                guard !next.gameApplicationIDs.contains(game.id) else { return }
                next.gameApplicationIDs.append(game.id)
                save(next)
            }
        }
    }

    private func privacy(_ profile: Binding<GuildProfile>) -> some View {
        SettingsGroup("Privacy") {
            SettingsCard {
                SettingsToggle(
                    title: "Private profile",
                    help: "Only members can see this server's profile. "
                        + "Everyone else sees a placeholder unless they have an invite.",
                    isOn: Binding(
                        get: { profile.wrappedValue.isPrivateProfile },
                        set: { isPrivate in
                            var next = profile.wrappedValue
                            // 1 ⇄ 2. Not a boolean on the wire, and the third
                            // value — public with recruitment — belongs to the
                            // Access page's "Apply to Join", so a switch here
                            // must never write it.
                            next.visibility = isPrivate ? 2 : 1
                            save(next)
                        }
                    )
                )
            }
        }
    }

    // MARK: Plumbing

    /// A binding into the local draft that falls back to the fetched value.
    ///
    /// The fallback matters for one frame: `adopt` runs in a `task`, so the
    /// first body evaluation after a fetch has no draft yet, and a binding that
    /// returned a blank profile there would flash an empty name field.
    private func draftBinding(_ profile: GuildProfile) -> Binding<GuildProfile> {
        Binding(
            get: { draft ?? profile },
            set: { draft = $0 }
        )
    }

    private func adopt(_ profile: GuildProfile) {
        // Only when the identity changes, or every save would stamp the reader's
        // in-flight edits back over themselves.
        guard draft?.id != profile.id else { return }
        draft = profile
    }

    private func iconURL(_ profile: GuildProfile) -> URL? {
        profile.iconHash.flatMap { CDN.guildIcon(guildID: profile.id, hash: $0, side: 64) }
    }

    private func save(_ profile: GuildProfile, icon: ImageData?? = nil) {
        draft = profile
        Task { await store.saveProfile(profile, icon: icon) }
    }

    private func resolveGames(_ profile: GuildProfile) async {
        guard !profile.gameApplicationIDs.isEmpty else {
            games = []
            return
        }
        games = (try? await store.resolveGames(profile.gameApplicationIDs)) ?? []
    }
}

// MARK: - Server Tag

/// The two-to-four letters members wear beside their name.
///
/// **The same route as Server Profile**, which is the single most useful thing
/// the captures settled: this looks like its own surface and is four more fields
/// on the profile body. The page therefore edits the same `GuildProfile` value
/// and saves through the same call — see `updateGuildProfile`, which refuses to
/// send the tag fields at all where the server lacks `GUILD_TAGS`.
struct ServerTagPane: View {
    let store: ServerSettingsStore

    @State private var draft: GuildProfile?

    var body: some View {
        LoadableContent(store.profile) { profile in
            let binding = Binding(get: { draft ?? profile }, set: { draft = $0 })
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup("Tag") {
                    SettingsCard {
                        EditableTextRow(
                            title: "Letters",
                            help: "Two to four characters.",
                            placeholder: "TAG",
                            text: Binding(
                                get: { binding.wrappedValue.tag ?? "" },
                                set: { binding.wrappedValue.tag = $0.isEmpty ? nil : $0 }
                            ),
                            committed: profile.tag ?? ""
                        ) {
                            save(binding.wrappedValue)
                        }
                    }
                    SettingsFootnote(
                        "Members who wear your tag show these letters beside their "
                            + "name everywhere on Discord."
                    )
                }

                SettingsGroup("Badge") {
                    BadgePicker(
                        selection: Binding(
                            get: { GuildBadge(rawValue: binding.wrappedValue.badge) },
                            set: { badge in
                                guard let badge else { return }
                                var next = binding.wrappedValue
                                next.badge = badge.rawValue
                                save(next)
                            }
                        ),
                        features: profile.features
                    )
                }
            }
            .task(id: profile.id) {
                guard draft?.id != profile.id else { return }
                draft = profile
            }
        }
    }

    private func save(_ profile: GuildProfile) {
        draft = profile
        Task { await store.saveProfile(profile) }
    }
}

// MARK: - Engagement

struct EngagementPane: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.settings) { settings in
            VStack(alignment: .leading, spacing: 0) {
                systemMessages(settings)
                notifications(settings)
                inactivity(settings)
                widget(settings)
            }
        }
    }

    /// The four switches.
    ///
    /// **Every bit on the wire is a suppression**, so each switch is the
    /// inverse of its flag — `SystemChannelFlags.sends(_:)` is the one place
    /// that inversion is written, because four hand-written `!contains` calls is
    /// four chances to get one of them backwards on a server that has never
    /// touched them, where zero looks correct either way.
    private func systemMessages(_ settings: GuildSettings) -> some View {
        SettingsGroup("System Messages") {
            SettingsCard {
                ForEach(Array(SystemChannelFlags.engagementOrder.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { CardDivider() }
                    SettingsToggle(
                        title: entry.label,
                        isOn: Binding(
                            get: { settings.systemChannelFlags.sends(entry.flag) },
                            set: { sending in
                                saveEngagement(
                                    settings,
                                    flags: settings.systemChannelFlags
                                        .setting(entry.flag, sending: sending)
                                )
                            }
                        )
                    )
                }
                CardDivider()
                channelPicker(
                    "System messages channel",
                    help: "Where member joins and boosts are announced.",
                    selection: settings.systemChannelID,
                    channels: store.textChannels,
                    noneTitle: "No system messages"
                ) { channelID in
                    saveEngagement(settings, systemChannelID: .some(channelID))
                }
            }
        }
    }

    private func notifications(_ settings: GuildSettings) -> some View {
        SettingsGroup("Default Notifications") {
            SettingsCard {
                SettingsPickerRow(
                    title: "New members receive",
                    options: [
                        .init(NotificationLevel.allMessages, NotificationLevel.allMessages.title),
                        .init(NotificationLevel.onlyMentions, NotificationLevel.onlyMentions.title),
                    ],
                    selection: Binding(
                        get: { settings.defaultMessageNotifications },
                        set: { saveEngagement(settings, notifications: $0) }
                    )
                )
            }
            SettingsFootnote(
                "What members get notified about until they choose for themselves. "
                    + "Only @mentions is the kinder default for a busy server."
            )
        }
    }

    private func inactivity(_ settings: GuildSettings) -> some View {
        SettingsGroup("Inactivity") {
            SettingsCard {
                channelPicker(
                    "Inactive channel",
                    help: "Members idle for longer than the timeout are moved here and muted.",
                    selection: settings.afkChannelID,
                    channels: store.voiceChannels,
                    noneTitle: "No inactive channel"
                ) { channelID in
                    saveEngagement(settings, afkChannelID: .some(channelID))
                }
                CardDivider()
                SettingsPickerRow(
                    title: "Inactive timeout",
                    options: AFKTimeout.seconds.map { .init($0, AFKTimeout.title($0)) },
                    selection: Binding(
                        get: { settings.afkTimeout },
                        set: { saveEngagement(settings, afkTimeout: $0) }
                    ),
                    // Meaningless without somewhere to move people to, and a
                    // menu that changes a number nothing reads is a control that
                    // does nothing. §5.5.
                    isEnabled: settings.afkChannelID != nil
                )
            }
        }
    }

    private func widget(_ settings: GuildSettings) -> some View {
        SettingsGroup("Server Widget") {
            LoadableContent(store.widget) { widget in
                SettingsCard {
                    SettingsToggle(
                        title: "Enable server widget",
                        isOn: Binding(
                            get: { widget.isEnabled },
                            set: { isOn in
                                Task {
                                    await store.saveWidget(
                                        isEnabled: isOn,
                                        channelID: widget.channelID
                                    )
                                }
                            }
                        )
                    )
                    if widget.isEnabled {
                        CardDivider()
                        channelPicker(
                            "Invite channel",
                            help: "The widget generates an invite to this channel.",
                            selection: widget.channelID,
                            channels: store.textChannels,
                            noneTitle: "No invite"
                        ) { channelID in
                            Task {
                                await store.saveWidget(
                                    isEnabled: widget.isEnabled,
                                    channelID: channelID
                                )
                            }
                        }
                    }
                }
            }
            SettingsFootnote(
                "An HTML widget for your own website, showing who is online and a "
                    + "link to join."
            )
        }
    }

    // MARK: Plumbing

    /// A channel menu with a real "none" entry.
    ///
    /// Every one of these maps to a nullable field, so "No inactive channel" has
    /// to be pickable — a menu that can only ever set a channel is a menu that
    /// cannot undo the first choice made in it.
    private func channelPicker(
        _ title: String,
        help: String?,
        selection: ChannelID?,
        channels: [ServerSettingsStore.ChannelSummary],
        noneTitle: String,
        set: @escaping @MainActor (ChannelID?) -> Void
    ) -> some View {
        SettingsPickerRow(
            title: title,
            help: help,
            options: [SettingsPickerRow<ChannelID?>.Option(nil, noneTitle)]
                + channels.map { .init($0.id, "#\($0.name)") },
            selection: Binding(get: { selection }, set: set)
        )
    }

    /// One save, taking the fields the Engagement page owns.
    ///
    /// Defaulted to the settings' current values so a caller changes one and the
    /// rest go back unchanged — which is what the route requires, and is exactly
    /// the "a page sends the fields it owns" rule made local.
    private func saveEngagement(
        _ settings: GuildSettings,
        systemChannelID: ChannelID?? = nil,
        flags: SystemChannelFlags? = nil,
        notifications: NotificationLevel? = nil,
        afkChannelID: ChannelID?? = nil,
        afkTimeout: Int? = nil
    ) {
        Task {
            await store.saveEngagement(
                systemChannelID: systemChannelID ?? settings.systemChannelID,
                systemChannelFlags: flags ?? settings.systemChannelFlags,
                defaultMessageNotifications: notifications ?? settings.defaultMessageNotifications,
                afkChannelID: afkChannelID ?? settings.afkChannelID,
                afkTimeout: afkTimeout ?? settings.afkTimeout
            )
        }
    }
}
