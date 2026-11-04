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
    let model: AppModel

    @Environment(\.colorScheme) private var colorScheme
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
        SettingsGroup {
            SettingsCard {
                EditableTextRow(
                    title: "Name",
                    placeholder: "Name",
                    text: profile.name,
                    committed: committed.name
                ) {
                    save(profile.wrappedValue)
                }
                CardDivider()
                ImageWell(
                    title: "Icon",
                    detail: "We recommend an image of at least 512x512.",
                    url: iconURL(profile.wrappedValue),
                    isCircular: true,
                    allowsAnimated: BoostTier.unlocks(
                        .animatedIcon,
                        features: profile.wrappedValue.features,
                        premiumTier: store.settings.value?.premiumTier ?? 0
                    ),
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
        let current = profile.wrappedValue
        let usesCustomBanner = isDiscoverable(current) && current.customBannerHash != nil
        return SettingsGroup("Banner") {
            SettingsCard {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: Spacing.base),
                        count: 4
                    ),
                    spacing: Spacing.base
                ) {
                    BrandSwatch(
                        colour: iconColour(current),
                        name: "Server Icon Color",
                        isSelected: !usesCustomBanner && current.brandColorPrimary == nil
                    ) {
                        choose(nil, in: current)
                    }
                    ForEach(BrandColor.presets) { preset in
                        BrandSwatch(
                            colour: preset.value,
                            name: preset.name,
                            isSelected: !usesCustomBanner && current.brandColorPrimary == preset.value
                        ) {
                            choose(preset.value, in: current)
                        }
                    }
                    if isDiscoverable(current) {
                        CustomBannerTile(
                            url: current.customBannerHash.flatMap {
                                CDN.guildDiscoverySplash(guildID: current.id, hash: $0, width: 300)
                            },
                            isSelected: usesCustomBanner
                        ) { image in
                            save(current, customBanner: .some(image))
                        }
                    }
                }
                .padding(SettingsMetrics.cardContentInset)
            }
        }
        // The first tile's colour is the icon's first swatch, read once per
        // picture through the palette table every card already shares.
        .task(id: current.iconHash) {
            model.sessionController.deriveBannerColor(
                guildID: current.id,
                iconHash: current.iconHash,
                brandColor: nil
            )
        }
    }

    /// The "Server Icon Color" tile: the icon's first swatch, else Discord's
    /// neutral — `aG` with `GUILD_PROFILE_BANNER_BACKGROUND_DEFAULT` as its
    /// fallback.
    private func iconColour(_ profile: GuildProfile) -> UInt32 {
        profile.iconHash
            .flatMap { GuildBannerArt.paletteURL(guildID: profile.id, iconHash: $0) }
            .flatMap { model.derivedPalettes[$0]?.first }
            ?? GuildBannerArt.defaultColour(isLight: colorScheme == .light)
    }

    /// Discord's own write for a tile: the colour, and the custom banner
    /// cleared with it — `updateGuildProfile(id, {brandColorPrimary, customBanner: null})`.
    private func choose(_ colour: UInt32?, in profile: GuildProfile) {
        var next = profile
        next.brandColorPrimary = colour
        let clearsBanner = profile.customBannerHash != nil
        if clearsBanner { next.customBannerHash = nil }
        save(next, customBanner: clearsBanner ? .some(nil) : nil)
    }

    /// The custom banner tile exists only for a discoverable server — Discord's
    /// `Is` returns nothing otherwise, and the artwork is shown nowhere else.
    private func isDiscoverable(_ profile: GuildProfile) -> Bool {
        profile.features.contains("DISCOVERABLE")
    }

    private func traits(_ profile: Binding<GuildProfile>) -> some View {
        SettingsGroup("Traits") {
            SettingsCard {
                TraitEditor(traits: profile.traits, isEnabled: true) {
                    save(profile.wrappedValue)
                }
            }
            SettingsFootnote("Add up to 5 traits to show off your server\u{2019}s interests and personality.")
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
            Text("What games does your server play?")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .padding(.bottom, Spacing.snug)
            SettingsCard {
                if !games.isEmpty {
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
                    CardDivider()
                }
                SettingsActionRow(
                    "Your Members Play",
                    actionTitle: "Search for a game..."
                ) {
                    isPickingGames = true
                }
            }
        }
        .modal(isPresented: $isPickingGames) {
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

    /// Discord's Private Profile (`IH`): the switch, its sentence, and beside
    /// it the card a stranger sees once it is on — "Private Server", "The
    /// server has limited who can see this profile." A discoverable server
    /// cannot hide its profile, and says where that is changed.
    private func privacy(_ profile: Binding<GuildProfile>) -> some View {
        let isDiscoverable = profile.wrappedValue.features.contains("DISCOVERABLE")
        return SettingsGroup {
            SettingsCard {
                HStack(alignment: .top, spacing: Spacing.margin) {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Toggle(isOn: Binding(
                            get: { profile.wrappedValue.isPrivateProfile },
                            set: { isPrivate in
                                var next = profile.wrappedValue
                                // Discord's: private is visibility 2; back out of
                                // it is 1 — the third value, public with
                                // recruitment, belongs to Access's Apply from
                                // Profile.
                                next.visibility = isPrivate ? 2 : 1
                                save(next)
                            }
                        )) {
                            Text("Private Profile")
                                .font(SettingsType.rowTitle)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(SettingsSurface.switchOn)
                        .disabled(isDiscoverable)
                        Text("When enabled, only server members can view profile content. Non-members won\u{2019}t be able to see this content unless they have an invite.")
                            .font(SettingsType.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if isDiscoverable {
                            Text("Discoverable servers cannot have their content hidden. You can change this setting in Access")
                                .font(.system(.caption))
                                .foregroundStyle(Ink.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PrivateProfilePreview(guildID: profile.wrappedValue.id)
                        // Discord shows the private card faded until it is on.
                        .opacity(profile.wrappedValue.isPrivateProfile ? 1 : 0.45)
                }
                .padding(SettingsMetrics.cardContentInset)
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

    private func save(
        _ profile: GuildProfile,
        icon: ImageData?? = nil,
        customBanner: ImageData?? = nil
    ) {
        draft = profile
        Task { await store.saveProfile(profile, icon: icon, customBanner: customBanner) }
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
                SettingsGroup("Customize Server Tag") {
                    Text("Create a tag that your server members can display next to their name! Anyone outside your server can view your Server Profile through the Server Tag, and if applications are enabled, they can apply to join.")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Spacing.snug)
                    SettingsCard {
                        EditableTextRow(
                            title: "Server Tag Name",
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
                }

                SettingsGroup("Choose Badge") {
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
    /// The server's size, which decides the Activity Feed's default.
    var memberCount: Int?

    var body: some View {
        LoadableContent(store.settings) { settings in
            VStack(alignment: .leading, spacing: 0) {
                // Discord's order (`pJ`): summaries, system messages, the feed.
                if settings.offersChannelSummaries {
                    channelSummaries(settings)
                }
                systemMessages(settings)
                activityFeed(settings)
                notifications(settings)
                inactivity(settings)
                widget(settings)
            }
        }
    }

    /// Discord's Channel Summaries (`pG`): one feature an administrator turns
    /// on, for a server Discord has released them to.
    private func channelSummaries(_ settings: GuildSettings) -> some View {
        SettingsGroup("Channel Summaries") {
            Text("Enable Channel Summaries for this server to help your members catch up and dive into discussions. In text channels, members will be able to see a list of topics being discussed and which members are involved.")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.snug)
            SettingsCard {
                SettingsToggle(
                    title: "Enable Channel Summaries",
                    isOn: Binding(
                        get: { settings.hasChannelSummaries },
                        set: { isOn in
                            Task { await store.setFeature("SUMMARIES_ENABLED_BY_USER", isOn: isOn) }
                        }
                    )
                )
            }
        }
    }

    /// Discord's Activity Feed Settings (`ph`): a pair of features, one set
    /// and the other cleared, over a default by the server's size.
    private func activityFeed(_ settings: GuildSettings) -> some View {
        SettingsGroup("Activity Feed Settings") {
            Text("Shows a feed of activity from games and connected apps in this server.")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.snug)
            SettingsCard {
                SettingsToggle(
                    title: "Display Activity Feed in this server",
                    isOn: Binding(
                        get: { settings.showsActivityFeed(memberCount: memberCount) },
                        set: { isOn in
                            let (on, off) = ("ACTIVITY_FEED_ENABLED_BY_USER", "ACTIVITY_FEED_DISABLED_BY_USER")
                            Task {
                                await store.setFeatures(
                                    adding: [isOn ? on : off],
                                    removing: [isOn ? off : on]
                                )
                            }
                        }
                    )
                )
            }
        }
    }

    /// The switches — `SystemChannelFlags.engagementRows`.
    ///
    /// **Every bit on the wire is a suppression**, so each switch is the
    /// inverse of its flag — `SystemChannelFlags.sends(_:)` is the one place
    /// that inversion is written, because four hand-written `!contains` calls is
    /// four chances to get one of them backwards on a server that has never
    /// touched them, where zero looks correct either way.
    private func systemMessages(_ settings: GuildSettings) -> some View {
        SettingsGroup("System Messages") {
            Text("Configure system event messages sent to your server.")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .padding(.bottom, Spacing.snug)
            SettingsCard {
                let rows = SystemChannelFlags.engagementRows(
                    features: settings.features,
                    flags: settings.systemChannelFlags
                )
                ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
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
                    "System Messages Channel",
                    help: "This is the channel we send system event messages to.",
                    selection: settings.systemChannelID,
                    channels: store.textChannels,
                    noneTitle: "No System Messages"
                ) { channelID in
                    saveEngagement(settings, systemChannelID: .some(channelID))
                }
            }
        }
    }

    private func notifications(_ settings: GuildSettings) -> some View {
        SettingsGroup("Default Notification Settings") {
            SettingsCard {
                SettingsPickerRow(
                    title: "Default Notification Settings",
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
                "This will determine whether members who have not explicitly set their notification settings receive a notification for every message sent in this server or not. We highly recommend setting this to only @mentions for a Community Server."
            )
        }
    }

    private func inactivity(_ settings: GuildSettings) -> some View {
        SettingsGroup("Inactive Channel") {
            SettingsCard {
                channelPicker(
                    "Inactive Channel",
                    help: "Automatically move members to this channel and mute them when they have been idle for longer than the inactive timeout. This does not affect browsers.",
                    selection: settings.afkChannelID,
                    channels: store.voiceChannels,
                    noneTitle: "No Inactive Channel"
                ) { channelID in
                    saveEngagement(settings, afkChannelID: .some(channelID))
                }
                CardDivider()
                SettingsPickerRow(
                    title: "Inactive Timeout",
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
                        title: "Enable Server Widget",
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
                            "Invite Channel",
                            help: "If a channel is selected then an invite link will be generated with the widget, otherwise only online members and voice channels will be provided.",
                            selection: widget.channelID,
                            channels: store.textChannels,
                            noneTitle: "No Invite"
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
                "Embed an HTML widget on your website to display your online members, voice channels, and invite link."
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

/// What a stranger sees of a private server: Discord's placeholder card —
/// "Private Server", a "?" for the icon, and its one sentence.
private struct PrivateProfilePreview: View {
    var guildID: GuildID

    var body: some View {
        let card = GuildProfilePresentation(
            guildID: guildID,
            name: "Private Server",
            tag: nil,
            iconURL: nil,
            monogram: "?",
            bannerURL: nil,
            bannerColor: nil,
            badgeURL: nil,
            mark: nil,
            description: nil,
            memberCount: nil,
            onlineCount: nil,
            traits: [],
            games: [],
            createdAt: guildID.timestamp,
            isJoined: false,
            isLoading: false,
            entry: .none
        )
        return GuildProfileCard(profile: card, openGuild: { _ in })
            .background(Palette.surfaceRaised)
            .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
            .scaleEffect(0.8, anchor: .topTrailing)
            .frame(width: 256, height: 220, alignment: .topTrailing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
