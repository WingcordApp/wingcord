import AppKit
import SwiftUI
import WingcordCore
import WingcordNet

// MARK: - The panes
//
// One view type for the detail column — §1 — branching internally on the
// section. An internal `switch` under a stable outer type is not a structural
// swap, so macOS never re-resolves the split on a selection change.
//
// Every pane is built from the vocabulary in `SettingsRows.swift` and nothing
// else. A pane that reaches for a bespoke row is a pane that has drifted.

struct SettingsPaneContent: View {
    var section: SettingsSection

    var body: some View {
        SettingsStack {
            // One hero per pane, from the catalog. Account and About draw their
            // own — a person's avatar and the app's mark say more than a tinted
            // tile of the same symbol already in the source list.
            if section != .account, section != .about {
                SettingsHero(
                    symbolName: section.symbolName,
                    tint: section.tint,
                    title: section.title,
                    subtitle: section.summary
                )
            }
            switch section {
            case .account: AccountPane()
            case .privacySafety: PrivacySafetyPane()
            case .connections: ConnectedAppsPane()
            case .general: GeneralPane()
            case .appearance: AppearancePane()
            case .accessibility: AccessibilityPane()
            case .notifications: NotificationsPane()
            case .shortcuts: ShortcutsPane()
            case .chat: ChatPane()
            case .voiceVideo: VoiceVideoPane()
            case .activity: ActivityPane()
            case .overlay: OverlayPane()
            case .clips: ClipsPane()
            case .streamerMode: StreamerModePane()
            case .extras: ExtrasPane()
            case .performance: PerformancePane()
            case .diagnostics: DiagnosticsPane()
            case .experiments: ExperimentsPane()
            case .about: AboutPane()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var settings = AppSettings.shared
    @Environment(\.settingsNavigate) private var navigate

    var body: some View {
        SettingsCard {
            CardHeaderRow(
                title: "On launch",
                help: "Where Wingcord opens when it starts."
            )
            SettingsSegmentedControl(
                selection: $settings.launchDestination,
                options: [
                    .init(.lastChannel, "Last channel", symbolName: "clock.arrow.circlepath"),
                    .init(.home, "Direct messages", symbolName: "bubble.left.and.bubble.right"),
                ]
            )
            CardDivider()
            SettingsActionRow(
                "Language",
                help: "Wingcord speaks your Mac\u{2019}s language. Dates, times and numbers follow it too.",
                actionTitle: "System Settings"
            ) {
                open("x-apple.systempreferences:com.apple.Localization-Settings.extension")
            }
        }

        SettingsGroup("Appearance and access") {
            SettingsCard {
                SettingsNavigationRow(
                    title: "Appearance",
                    subtitle: SettingsSection.appearance.summary,
                    symbolName: SettingsSection.appearance.symbolName,
                    tint: SettingsSection.appearance.tint
                ) { navigate(.appearance) }
                CardDivider()
                SettingsNavigationRow(
                    title: "Permissions",
                    subtitle: "What macOS lets Wingcord do, in System Settings.",
                    symbolName: "checkmark.shield.fill",
                    tint: Color(hex: 0x30D158)
                ) {
                    open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                }
            }
        }

        SettingsGroup("Window") {
            SettingsCard {
                SettingsToggle(
                    title: "Show the member list by default",
                    help: "New windows open with the member list showing. The toolbar button still hides it per conversation.",
                    isOn: $settings.showsMemberListByDefault
                )
            }
        }

        SettingsGroup("Advanced") {
            SettingsCard {
                SettingsToggle(
                    title: "Developer mode",
                    help: "Adds Copy ID to the menus of messages, people, channels and servers.",
                    isOn: $settings.developerMode
                )
            }

            SettingsCard {
                SettingsNavigationRow(
                    title: "Experiments",
                    subtitle: SettingsSection.experiments.summary,
                    symbolName: SettingsSection.experiments.symbolName,
                    tint: SettingsSection.experiments.tint
                ) { navigate(.experiments) }
                CardDivider()
                SettingsNavigationRow(
                    title: "Extras",
                    subtitle: SettingsSection.extras.summary,
                    symbolName: SettingsSection.extras.symbolName,
                    tint: SettingsSection.extras.tint
                ) { navigate(.extras) }
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Extras

/// Wingcord's own additions — the Vencord plugins it carries — in a pane of
/// their own (D10a), where they used to hide under General › Advanced.
private struct ExtrasPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Vencord's Fake Nitro (decision 9), its switches in plain words
            // (D10e) — the plugin's own read like its source.
            SettingsCard {
                SettingsToggle(
                    title: "Fake Nitro",
                    help: "Nitro\u{2019}s emoji, stickers and stream quality, without Nitro.",
                    isOn: $settings.fakeNitro
                )
                if settings.fakeNitro {
                    CardDivider()
                    SettingsToggle(
                        title: "Emoji",
                        help: "Send emoji from any server, even where custom emoji aren\u{2019}t allowed.",
                        isOn: $settings.fakeNitroEmoji
                    )
                    CardDivider()
                    SettingsToggle(
                        title: "Stickers",
                        help: "Send stickers from any server, even where stickers aren\u{2019}t allowed.",
                        isOn: $settings.fakeNitroStickers
                    )
                    CardDivider()
                    SettingsToggle(
                        title: "Stream quality",
                        help: "Go live at Nitro\u{2019}s resolution and frame rate.",
                        isOn: $settings.fakeNitroStreamQuality
                    )
                    CardDivider()
                    SettingsToggle(
                        title: "Skip the embed check",
                        help: "Sends without asking first in a channel that won\u{2019}t show the links as pictures.",
                        isOn: $settings.fakeNitroSkipsEmbedCheck
                    )
                }
            }
            .padding(.top, SettingsMetrics.cardToHeader)
            SettingsFootnote(
                "People without Fake Nitro see a link instead. Discord can act on accounts that use it.",
                symbolName: "sparkles"
            )

            // Vencord's AnonymiseFileNames (decision 11): the switch, then
            // each of its settings, and the two that belong to one method
            // dimmed under the others, as the plugin's are.
            SettingsCard {
                SettingsToggle(
                    title: "Anonymise File Names",
                    help: "Uploads go out under a new name, so a file\u{2019}s name gives nothing away.",
                    isOn: $settings.anonymisesFileNames
                )
                if settings.anonymisesFileNames {
                    CardDivider()
                    SettingsToggle(
                        title: "Anonymise by default",
                        help: "New uploads start anonymised. Each file\u{2019}s incognito button switches it.",
                        isOn: $settings.anonymisesByDefault
                    )
                    CardDivider()
                    SettingsFlyoutRow(
                        "Method",
                        help: "How the new name is made.",
                        selection: $settings.anonymisingMethod,
                        options: FileNameAnonymiser.Method.allCases,
                        title: \.title
                    )
                    CardDivider()
                    SettingsControlRow("Randomised length", help: "How many characters a random name has.") {
                        HStack(spacing: Spacing.tight) {
                            TextField("", value: $settings.randomisedLength, format: .number)
                                .modalField()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 48)
                            Stepper("", value: $settings.randomisedLength, in: AppSettings.randomisedLengths)
                                .labelsHidden()
                        }
                        .controlSize(.small)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Randomised length"))
                    }
                    .disabled(settings.anonymisingMethod != .randomCharacters)
                    CardDivider()
                    SettingsControlRow("Consistent name", help: "The name every upload gets with Consistent.") {
                        TextField("", text: $settings.consistentFileName)
                            .modalField()
                            .controlSize(.small)
                            .frame(width: 140)
                            .accessibilityLabel(Text("Consistent name"))
                    }
                    .disabled(settings.anonymisingMethod != .consistent)
                }
            }
            .padding(.top, SettingsMetrics.cardToHeader)

            // Vencord's SilentTyping (decision 16), as the card above is.
            SettingsCard {
                SettingsToggle(
                    title: "Silent Typing",
                    help: "Write without anyone seeing \u{201C}typing\u{2026}\u{201D}.",
                    isOn: $settings.silentTyping
                )
                if settings.silentTyping {
                    CardDivider()
                    SettingsToggle(
                        title: "Composer button",
                        help: "A keyboard button beside the message field turns it on and off.",
                        isOn: $settings.silentTypingShowsIcon
                    )
                    CardDivider()
                    SettingsToggle(
                        title: "In the field\u{2019}s menu",
                        help: "Right-click the message field to turn it on and off.",
                        isOn: $settings.silentTypingInContextMenu
                    )
                    CardDivider()
                    SettingsToggle(
                        title: "Hide my typing",
                        help: "What the button and the menu switch. Off, people see you typing again.",
                        isOn: $settings.silentTypingIsOn
                    )
                }
            }
            .padding(.top, SettingsMetrics.cardToHeader)
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @State private var settings = AppSettings.shared
    @State private var theme = ThemeStore.shared
    @Environment(\.motion) private var motion
    /// The selection ring's, and owned here because it has to span every
    /// gallery: the choice is one choice. See `ThemeGallery`.
    @Namespace private var themeRing
    /// Which shelf of looks is open — the shelf the theme in use is on, the
    /// first time the pane opens.
    @State private var shelf: LookShelf

    init() {
        _shelf = State(initialValue: LookShelf(holding: ThemeStore.shared.choice))
    }

    var body: some View {
        // **One look picker** (D10b; Alex, 2026-10-26: "there's 3 different
        // pickers … i was thinking of unifying it"). The window as it will
        // look on top, the native segmented strip under it, and one grid —
        // Wingcord's themes, Discord's, the saved ones, or a picture behind
        // whichever is chosen. The three theme shelves share one selection
        // ring, because choosing a theme anywhere is one choice.
        SettingsGroup("Look") {
            SettingsMessagePreview()
            SegmentedPicker(
                options: LookShelf.allCases.map { .init($0, $0.title) },
                selection: $shelf.animation(motion.standard),
                fillsWidth: true
            )
            .padding(.top, SettingsMetrics.cardToHeader)
            ZStack(alignment: .top) {
                switch shelf {
                case .wingcord:
                    ThemeGallery(ring: themeRing)
                        .transition(.opacity)
                case .discord:
                    DiscordThemeGallery(ring: themeRing)
                        .transition(.opacity)
                case .saved:
                    SavedThemeGallery(ring: themeRing)
                        .transition(.opacity)
                case .pictures:
                    WallpaperSettingsCard()
                        .transition(.opacity)
                }
            }
            .padding(.top, SettingsMetrics.headerToCard)
            if shelf != .pictures {
                SettingsCard {
                    SettingsSliderRow(
                        title: "Vividness",
                        help: "How much colour and glow your theme gives off. Names stay readable at any setting.",
                        value: $theme.vividness,
                        range: 0...1,
                        step: 0.05,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        onEditingChanged: { editing in
                            if editing { theme.beginAdjusting() } else { theme.endAdjusting() }
                        }
                    )
                    .disabled(theme.choice.isStated)
                }
                .padding(.top, SettingsMetrics.cardToHeader)
            }
        }

        // Only while it is the theme in use. A picker for a blend nobody has
        // selected is a control whose every move is invisible.
        //
        // The group is always in the tree and its *contents* come and go, which
        // is what gives the animation something stable to run on: a conditional
        // wrapped around the group itself would be a structural change to the
        // pane, and the card would appear at full height with no transition at
        // all.
        SettingsGroup {
            if theme.choice.isCustom {
                PlumageCard()
                    .transition(.opacity)
            }
        }
        .animation(motion.standard, value: theme.choice.isCustom)

        SettingsGroup("Everywhere you go") {
            ThemeSyncCard()
            ServerThemePreferenceCard()
        }

        SettingsGroup("Window") {
            SettingsCard {
                CardHeaderRow(
                    title: "Sidebar",
                    help: "Floating hovers it over the background as glass. "
                        + "Docked runs it flush with the window\u{2019}s edge."
                )
                SettingsSegmentedControl(
                    selection: Binding(
                        get: { settings.sidebarStyle },
                        set: { ShellActions.setSidebarStyle($0) }
                    ),
                    options: SidebarStyle.allCases.map {
                        .init($0, $0.label, symbolName: $0 == .floating ? "sidebar.squares.leading" : "sidebar.leading")
                    }
                )
                CardDivider()
                CardHeaderRow(
                    title: "Pages",
                    help: "Swipe the sidebar with two fingers between your messages and your servers. "
                        + "Three pages give your servers a list of their own."
                )
                SettingsSegmentedControl(
                    selection: $settings.sidebarPages,
                    options: SidebarPageLayout.allCases.map {
                        .init($0, $0.label, symbolName: $0 == .twoPages ? "rectangle.split.2x1" : "rectangle.split.3x1")
                    }
                )
                CardDivider()
                SettingsToggle(
                    title: "Server banners",
                    help: "The server\u{2019}s art across the top of its channel list.",
                    isOn: $settings.showsServerBanners
                )
                CardDivider()
                SettingsToggle(
                    title: "Message previews",
                    help: "The newest message under each conversation in your list.",
                    isOn: $settings.loadsMessagePreviews
                )
            }
        }

        SettingsGroup("Bars") {
            SettingsCard {
                CardHeaderRow(
                    title: "Shape",
                    help: "Pill keeps the round buttons beside the bar. Boxy holds them inside it."
                )
                SettingsSegmentedControl(
                    selection: $settings.chromeShape,
                    options: ChromeShape.allCases.map {
                        .init($0, $0.label, symbolName: $0.symbolName)
                    }
                )
                CardDivider()
                SettingsToggle(
                    title: "GIF, sticker and app buttons in the bar",
                    help: "Off, they move into the + menu and the bar keeps just emoji and send.",
                    isOn: $settings.composerControlsInline
                )
                CardDivider()
                SettingsChromePreview(
                    shape: settings.chromeShape,
                    controls: $settings.composerControls
                )
                CardDivider()
                SettingsToggle(
                    title: "Show my nameplate",
                    help: "Your nameplate behind your name, at the foot of the sidebar.",
                    isOn: $settings.showsNameplateInNowBar
                )
            }
            SettingsFootnote("Drag the buttons to rearrange them.", symbolName: "hand.draw")
        }

        // **Messages, once** (D10a): bubbles, density, timestamps and size,
        // beside one another under the one preview at the top of the pane.
        // Timestamps were in Messages as well, and the colour people bring in
        // Accessibility too — two controls for one setting is how a reader
        // cannot tell which one won, so each lives in one place.
        SettingsGroup("Bubbles") {
            SettingsCard {
                SettingsToggle(
                    title: "Messages in bubbles",
                    help: "Yours on the right, everyone else's on the left — "
                        + "the way Messages draws a conversation.",
                    isOn: $settings.usesMessageBubbles
                )
                CardDivider()
                SettingsToggle(
                    title: "Tint my messages with the accent",
                    help: "Your bubbles in the accent colour rather than frosted glass.",
                    isOn: $settings.tintsOwnBubbles
                )
                .disabled(!settings.usesMessageBubbles)
                CardDivider()
                SettingsToggle(
                    title: "Screen effects",
                    help: "Balloons for a happy birthday, confetti for congratulations, "
                        + "fireworks for New Year. Skipped while Reduce Motion is on.",
                    isOn: $settings.playsScreenEffects
                )
            }
        }

        SettingsGroup("Density") {
            SettingsCard {
                CardHeaderRow(
                    title: "Message density",
                    help: "Compact fits more on screen, with less room between messages."
                )
                SettingsSegmentedControl(
                    selection: $settings.isCompactMode,
                    options: [
                        .init(false, "Comfortable", symbolName: "rectangle.expand.vertical"),
                        .init(true, "Compact", symbolName: "rectangle.compress.vertical"),
                    ]
                )
                CardDivider()
                SettingsSliderRow(
                    title: "Space between groups",
                    help: "Extra room between one person\u{2019}s messages and the next person\u{2019}s.",
                    value: $settings.messageGroupSpacing,
                    range: 0...24,
                    step: 1,
                    format: { "\(Int($0)) pt" }
                )
            }
        }

        SettingsGroup("Timestamps") {
            SettingsCard {
                CardHeaderRow(title: "Clock", help: "12-hour or 24-hour times.")
                SettingsSegmentedControl(
                    selection: $settings.uses24HourTime,
                    options: [
                        .init(false, "12-hour", symbolName: "clock"),
                        .init(true, "24-hour", symbolName: "clock.badge.checkmark"),
                    ]
                )
                CardDivider()
                SettingsToggle(
                    title: "Show seconds",
                    help: "Adds seconds to every time.",
                    isOn: $settings.showsSeconds
                )
                CardDivider()
                SettingsToggle(
                    title: "Always show timestamps",
                    help: "A time beside every message, not just the one under the pointer.",
                    isOn: $settings.alwaysShowsTimestamps
                )
            }
        }

        SettingsGroup("Text") {
            SettingsCard {
                SettingsSliderRow(
                    title: "Message size",
                    help: "How big the text in conversations is. \u{2318}+ and \u{2318}\u{2212} change it too.",
                    value: $settings.textScale,
                    range: 0.8...1.6,
                    step: 0.05,
                    format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                )
            }
        }

    }
}

/// The shelves of the one look picker.
enum LookShelf: String, CaseIterable, Hashable, Sendable {
    case wingcord
    case discord
    case saved
    case pictures

    var title: String {
        switch self {
        case .wingcord: "Wingcord"
        case .discord: "Discord"
        case .saved: "Saved"
        case .pictures: "Pictures"
        }
    }

    /// The shelf a theme is on.
    init(holding choice: ThemeChoice) {
        switch choice {
        case .discord: self = .discord
        case .shared: self = .saved
        case .system, .preset, .custom: self = .wingcord
        }
    }
}

/// Appearance → Discord's two theme switches, in its words (DESIGN-NOTES §15).
///
/// "Sync theme across my devices" is off-limits while the theme follows the
/// computer, as Discord's is; turning it on sends the theme chosen here, as
/// Discord's does. "Apply theme to other users' profiles" draws a themed
/// profile in the reader's own light or dark.
private struct ThemeSyncCard: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    @State private var theme = ThemeStore.shared

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Sync theme across my devices",
                help: "Discord on your other devices wears the theme you pick here.",
                isOn: Binding(
                    get: { settings.syncsThemeAcrossDevices },
                    set: { syncs in
                        settings.syncsThemeAcrossDevices = syncs
                        if syncs { model.sessionController.writeAccountTheme(for: theme.choice) }
                    }
                )
            )
            .disabled(theme.choice == .system)
            CardDivider()
            SettingsToggle(
                title: "Apply theme to other users' profiles",
                help: "Other people\u{2019}s themed profiles in your own light or dark.",
                isOn: $settings.appliesThemeToProfiles
            )
        }
    }
}

/// Appearance → "Default theme in servers": Discord's own setting, and its own
/// two answers.
///
/// **Synced, not local**, which is why it reads the store rather than
/// `AppSettings`: it is `appearance.default_guild_theme_preference` in the
/// account's settings, so choosing here changes Discord too. Never touched
/// reads as the server's theme, as it does in Discord.
private struct ServerThemePreferenceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsCard {
            CardHeaderRow(
                title: "Default theme in servers",
                help: "Whose theme a server with a theme of its own is shown in."
            )
            SettingsSegmentedControl(
                selection: Binding(
                    get: { model.serverThemePreferences.default == .personal ? .personal : .guild },
                    set: { model.sessionController.setDefaultServerTheme($0) }
                ),
                options: [
                    .init(GuildThemeSource.guild, "Use the server's theme", symbolName: "paintpalette"),
                    .init(GuildThemeSource.personal, "Use my theme", symbolName: "person.crop.circle"),
                ]
            )
            // A write needs the account; signed out there is nothing to change.
            .disabled(model.connectionState != .ready)
        }
    }
}

// MARK: - Messages

private struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        // Timestamps are not here: they live once, in Appearance › Messages,
        // beside the bubbles and the density they are drawn with (D10a).
        SettingsGroup("Messages") {
            SettingsCard {
                SettingsToggle(
                    title: "Show link previews",
                    help: "Links unfold into a card with the page\u{2019}s picture and title.",
                    isOn: $settings.showsEmbeds
                )
                CardDivider()
                SettingsToggle(
                    title: "Load images automatically",
                    help: "Off, a picture waits until you open it.",
                    isOn: $settings.loadsImagesAutomatically
                )
                CardDivider()
                // Discord's own setting (`CHAT_THREADS_SPLIT_VIEW`), synced
                // with the account — see `SyncedPreferences`.
                SettingsToggle(
                    title: "Open threads in split view",
                    help: "A thread opens beside its channel instead of in its place.",
                    isOn: Binding(
                        get: { model.syncedPreferences.opensThreadsInSplitView },
                        set: { model.setOpensThreadsInSplitView($0) }
                    )
                )
            }
        }
        ExpressionsPane()
        MediaPane()
    }
}

// MARK: - Expressions

private struct ExpressionsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup("Emoji") {
            SettingsCard {
                CardHeaderRow(title: "Default skin tone", help: "For every emoji that comes in more than one.")
                SettingsSegmentedControl(
                    selection: $settings.skinTone,
                    options: UnicodeEmoji.SkinTone.allCases.map {
                        // The swatch alone. Six cells across a card is 81 points
                        // each, and "Medium-Light" does not fit in 81 points at any
                        // size worth reading — while a row of hands is the thing
                        // being chosen, shown directly.
                        .init($0, "", glyph: $0.swatch, spoken: $0.title)
                    }
                )
                CardDivider()
                SettingsToggle(
                    title: "Play animated emoji and avatars",
                    help: "Off, they hold still on their first frame. Easier on the battery.",
                    isOn: $settings.playsAnimatedContent
                )
            }
        }
    }
}

// MARK: - Media

private struct MediaPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup("Video and sound") {
            SettingsCard {
                SettingsSliderRow(
                    title: "Playback volume",
                    help: "Where the sound starts for every video you open.",
                    value: $settings.mediaVolume,
                    range: 0...1,
                    step: 0.05,
                    format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                )
                CardDivider()
                SettingsToggle(
                    title: "Start muted",
                    help: "Videos open silent. Unmuting brings back your volume.",
                    isOn: $settings.mutesMedia
                )
                CardDivider()
                SettingsToggle(
                    title: "Loop videos",
                    help: "A video starts again when it reaches the end.",
                    isOn: $settings.loopsVideo
                )
            }
        }

        // Discord's own switch and words (its mobile client's): a picture
        // over the limit is compressed to fit as it is added.
        SettingsGroup("Uploads") {
            SettingsCard {
                SettingsToggle(
                    title: "Auto-compress Images",
                    help: "When this is on, images sent will be compressed. Get Nitro to send a crystal clear image!",
                    isOn: $settings.autoCompressesImages
                )
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @State private var settings = AppSettings.shared
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Show unread counts",
                help: "The numbers on your servers and the Dock icon. Unread dots stay either way.",
                isOn: $settings.showsUnreadCounts
            )
        }

        SettingsGroup("Banners") {
            SettingsCard {
                SettingsToggle(
                    title: "Show notifications",
                    help: "A banner when a message lands somewhere you aren\u{2019}t reading.",
                    isOn: $settings.postsNotifications
                )
                CardDivider()
                SettingsToggle(
                    title: "Play a sound",
                    help: "The system's notification sound.",
                    isOn: $settings.playsNotificationSound
                )
                .disabled(!settings.postsNotifications)
                CardDivider()
                SettingsToggle(
                    title: "Only for mentions",
                    help: "Ignore each server's own setting and notify only when somebody mentions you.",
                    isOn: $settings.notifiesOnlyForMentions
                )
                .disabled(!settings.postsNotifications)
            }
            SettingsFootnote(
                "Nothing showing up? Check Wingcord in System Settings \u{203A} Notifications.",
                symbolName: "gear"
            )
        }

        // A macOS Focus, worn as a status — this Mac's, like the banners above.
        FocusSettingsGroup()

        // **Everything below follows the ACCOUNT, not this Mac.** The three
        // cards above are what this client does with a notification; these are
        // which kinds Discord sends at all, so turning one off here turns it off
        // on a phone too. Two groups rather than one list, because the
        // distinction is the only thing that makes the page comprehensible.
        accountSubscriptions
    }

    @ViewBuilder
    private var accountSubscriptions: some View {
        SettingsGroup("Notify me when…") {
            SettingsCard {
                ForEach(Array(NotificationSwitch.incoming.enumerated()), id: \.element) { entry in
                    if entry.offset > 0 { CardDivider() }
                    SettingsToggle(title: entry.element.title, isOn: subscription(entry.element))
                }
                CardDivider()
                SettingsFlyoutRow(
                    "Someone reacts to my messages",
                    selection: reactions,
                    options: ReactionNotifications.allCases,
                    title: \.title,
                    symbol: \.symbolName
                )
            }
            SettingsFootnote(
                "These follow your account to every device.",
                symbolName: "person.crop.circle.badge.checkmark"
            )
        }
        .disabled(model.notificationSubscriptionsRaw == nil)

        SettingsGroup("Let friends know when…") {
            SettingsCard {
                ForEach(Array(NotificationSwitch.outgoing.enumerated()), id: \.element) { entry in
                    if entry.offset > 0 { CardDivider() }
                    SettingsToggle(title: entry.element.title, isOn: subscription(entry.element))
                }
            }
        }
        .disabled(model.notificationSubscriptionsRaw == nil)

        SettingsGroup("Quiet") {
            SettingsCard {
                SettingsToggle(
                    title: "In-app notifications",
                    help: "The banner Discord shows inside the app itself.",
                    isOn: flag(\.showsInApp) { .showInApp($0) }
                )
                CardDivider()
                SettingsToggle(
                    title: "Quiet mode",
                    help: "Holds every notification back until you turn it off.",
                    isOn: flag(\.isQuiet) { .quietMode($0) }
                )
            }
        }
        .disabled(model.notificationSubscriptionsRaw == nil)
        .task { await model.sessionController.loadNotificationSubscriptions() }
    }

    /// One switch, written through the store and put back on refusal.
    private func subscription(_ item: NotificationSwitch) -> Binding<Bool> {
        Binding(
            get: { model.notificationSubscriptions[item] },
            set: { isOn in
                let previous = model.notificationSubscriptions
                model.notificationSubscriptions[item] = isOn
                model.sessionController.writeNotificationSubscription(
                    .item(item, isOn), restoring: previous
                )
            }
        )
    }

    private func flag(
        _ path: WritableKeyPath<NotificationSubscriptions, Bool>,
        _ change: @escaping (Bool) -> NotificationSettingsProto.Change
    ) -> Binding<Bool> {
        Binding(
            get: { model.notificationSubscriptions[keyPath: path] },
            set: { isOn in
                let previous = model.notificationSubscriptions
                model.notificationSubscriptions[keyPath: path] = isOn
                model.sessionController.writeNotificationSubscription(
                    change(isOn), restoring: previous
                )
            }
        )
    }

    private var reactions: Binding<ReactionNotifications> {
        Binding(
            get: { model.notificationSubscriptions.reactions },
            set: { scope in
                let previous = model.notificationSubscriptions
                model.notificationSubscriptions.reactions = scope
                model.sessionController.writeNotificationSubscription(
                    .reactions(scope), restoring: previous
                )
            }
        )
    }
}

// MARK: - Account

private struct AccountPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // In a stack of its own, so the fetch below is ONE task: a modifier on
        // a builder of several views lands on each of them, and this one asked
        // Discord for the account once per child.
        SettingsStack { content }
            // **Fetched when the pane opens, not held from launch.** The token
            // check at startup calls the same route and throws these fields
            // away deliberately: an e-mail address and a phone number kept for
            // a whole session are two secrets in memory for a page most readers
            // never open.
            .task { await model.sessionController.loadAccountDetails() }
    }

    @ViewBuilder
    private var content: some View {
        if let userID = model.currentUserID, let user = model.users[userID] {
            SettingsHero(title: user.preferredName, subtitle: user.handle) {
                AvatarView(
                    url: model.avatarURL(for: user, side: 64),
                    monogram: user.monogram,
                    side: 64
                )
            }
            AccountInfoCard(handle: user.handle, details: model.accountDetails)
        } else {
            SettingsCard {
                SettingsValueRow(
                    title: "Account",
                    value: "Not signed in",
                    help: "Sign in from the main window."
                )
            }
        }

        // Where the now bar's Manage Accounts lands, so it's up here rather than a scroll away.
        SettingsGroup("Accounts on this Mac") {
            SettingsCard {
                let accounts = model.storedAccounts
                ForEach(accounts.indices, id: \.self) { index in
                    if index > 0 { CardDivider() }
                    AccountSettingsRow(
                        account: accounts[index],
                        isCurrent: accounts[index].id == model.currentUserID?.description
                    )
                }
                if AccountList(accounts).canAdd {
                    if !accounts.isEmpty { CardDivider() }
                    SettingsActionRow("Add an Account", actionTitle: "Add") {
                        model.presentAddAccount()
                    }
                }
            }
            SettingsFootnote(
                "Kept in your Keychain, on this Mac only.",
                symbolName: "key.fill"
            )
        }
        .task { model.reloadAccounts() }

        SettingsGroup("Security") {
            AccountSecurityCard(details: model.accountDetails)
        }

        SettingsGroup("Signed in") {
            AuthSessionsCard(sessions: model.authSessions)
        }
        .task { await model.sessionController.loadAuthSessions() }

        SettingsGroup("Standing") {
            // Discord's order: the notice over the category, the age group,
            // then the standing itself.
            AgeGroupNotice(group: model.entitlements.ageGroup)
            SettingsCard { AgeGroupRow(group: model.entitlements.ageGroup) }
            AccountStandingCard(standing: model.accountStanding)
        }
        .task { model.sessionController.loadAccountStanding() }

    }
}

/// One account in Settings: its picture and name, and what can be done about it.
private struct AccountSettingsRow: View {
    @Environment(AppModel.self) private var model

    var account: StoredAccount
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: account.avatarURL(side: 32), monogram: account.monogram, side: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.preferredName)
                    .font(.system(.body, weight: .medium))
                Text(subtitle)
                    .font(.system(.caption))
                    .foregroundStyle(account.isSessionExpired ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
            }
            Spacer(minLength: Spacing.base)
            if !isCurrent {
                Button(account.isSessionExpired ? "Log In" : "Switch") {
                    model.requestAccountSwitch(to: account)
                }
            }
            Button("Log Out", role: .destructive) {
                model.requestLogOut(of: account)
            }
        }
        .padding(.vertical, Spacing.tight)
    }

    private var subtitle: String {
        if account.isSessionExpired { return "Session expired. Log in again." }
        return isCurrent ? "@\(account.username), using now" : "@\(account.username)"
    }
}

// MARK: - Privacy

private struct PrivacySafetyPane: View {
    var body: some View {
        MessagingPermissionsPane()
        SettingsGroup("Your data") {
            PrivacyPane()
        }
    }
}

private struct PrivacyPane: View {
    var body: some View {
        SettingsCard {
            SettingsValueRow(
                title: "Analytics",
                value: "None collected",
                help: "Wingcord talks to Discord and nobody else."
            )
            CardDivider()
            SettingsValueRow(
                title: "Crash reports",
                value: "Local only",
                help: "Saved on this Mac. Never sent anywhere."
            )
        }

        SettingsGroup("Terms") {
            SettingsCard {
                SettingsValueRow(title: "Client", value: "Third-party")
                CardDivider()
                SettingsValueRow(title: "Affiliation", value: "None")
            }
            SettingsFootnote(
                "Wingcord isn\u{2019}t made by Discord, and third-party clients are against its terms. Use it knowing that.",
                symbolName: "exclamationmark.triangle"
            )
        }
    }
}

// MARK: - Performance

private struct PerformancePane: View {
    @State private var settings = AppSettings.shared
    @State private var snapshot = PerformanceSnapshot.empty

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Show the performance inspector",
                help: "A live overlay of frame times, memory and caches.",
                isOn: $settings.showsPerformanceInspector
            )
        }

        SettingsGroup("Now") {
            SettingsCard {
                SettingsValueRow(
                    title: "Memory footprint",
                    value: snapshot.footprintDescription,
                    help: "What Activity Monitor shows for Wingcord."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Image cache budget",
                    value: snapshot.imageBudgetDescription,
                    help: Self.imageBudgetHelp
                )
                CardDivider()
                SettingsValueRow(
                    title: "Animation budget",
                    value: SettingsMeterRow.bytes(AnimatedImageStore.budget),
                    help: "The most animated emoji, decorations and profile effects may hold."
                )
                CardDivider()
                SettingsValueRow(title: "Loaded transcripts", value: "\(snapshot.residentChannels)")
                CardDivider()
                SettingsValueRow(title: "Messages held", value: "\(snapshot.residentMessages)")
                CardDivider()
                SettingsValueRow(title: "Slow frames (last 300)", value: "\(snapshot.slowFrames)")
            }
        }
        // Sampling runs only while this pane is on screen. `.task` cancels on
        // disappear, which is the whole reason it is used rather than a timer —
        // a settings pane nobody is looking at must not sample memory once a
        // second for the life of the process.
        .task {
            while !Task.isCancelled {
                snapshot = PerformanceMonitor.shared.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        // Frame timing exists only while the inspector's display link is
        // running, and the inspector is what starts it. Shown when it is on and
        // ABSENT when it is off, rather than shown as a row of zeroes: a
        // measurement that reads 0.0 ms because nothing measured it is worse
        // than no measurement, because it looks like a good one.
        if settings.showsPerformanceInspector {
            SettingsGroup("Frames") {
                SettingsCard {
                    SettingsValueRow(
                        title: "Last frame",
                        value: milliseconds(snapshot.lastFrameMilliseconds)
                    )
                    CardDivider()
                    SettingsValueRow(
                        title: "Worst recent frame",
                        value: milliseconds(snapshot.worstFrameMilliseconds),
                        help: "The slowest of the last 300 frames."
                    )
                    CardDivider()
                    SettingsValueRow(
                        title: "Display",
                        value: snapshot.displayHertz.formatted(
                            .number.precision(.fractionLength(0))
                        ) + " Hz",
                        help: "How long a frame has to be drawn in. At 120 Hz that\u{2019}s 8.3 ms."
                    )
                }
            }
        }

        // What Wingcord keeps on this Mac — Storage, folded in (D10a): the
        // cost of the app on the disk beside its cost in memory.
        SettingsGroup("Storage") {
            StoragePane()
        }
    }

    private func milliseconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    /// Read off `ImageStore.Budget`, so the sentence cannot drift from the
    /// table it describes.
    private static var imageBudgetHelp: String {
        typealias Budget = ImageStore.Budget
        let megabytes = { (bytes: Int) in bytes / (1024 * 1024) }
        return "The most the image caches may hold: avatars \(megabytes(Budget.thumbnails)) MB, "
            + "attachments \(megabytes(Budget.attachments)) MB, artwork \(megabytes(Budget.artwork)) MB, "
            + "and the viewer \(megabytes(Budget.stage)) MB while it\u{2019}s open."
    }
}

// MARK: - Accessibility

/// What the app is currently honouring, and where to change it.
///
/// **Deliberately not a pane of toggles.** Every setting below belongs to the
/// system, and the house rule is that a second switch for one behaviour leaves a
/// reader who set the system's and still sees the old behaviour unable to tell
/// which one won. So this pane reports rather than duplicates: it says what is on
/// and what the app does about it, and sends you to the one place that changes it.
///
/// Every value is a live environment read, so the pane follows a change made in
/// System Settings while it is open — the app already observes
/// `accessibilityDisplayOptionsDidChangeNotification` for the drawn surfaces.
private struct AccessibilityPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var settings = AppSettings.shared
    @State private var isConfirmingReset = false

    var body: some View {
        cosmetics
        readability
        voiceOver
        systemSettings
        reset
    }

    // MARK: Cosmetics

    /// **The reason this is the first card and not a footnote.** Everything in
    /// it is artwork somebody *else* bought, drawn on this reader's screen: a
    /// name set in a low-contrast gradient face, an effect animating behind a
    /// bio, a strip of colour across a whole row. None of it is this reader's
    /// choice and all of it is in their way, which is what makes it an
    /// accessibility control rather than a taste one.
    private var cosmetics: some View {
        SettingsGroup("Cosmetics") {
            SettingsCard {
                CardHeaderRow(
                    title: "Hide these",
                    help: "Decorations other people wear. Their words, names and badges stay."
                )
                SettingsCheckboxGrid(
                    options: CosmeticSuppression.all.map { .init($0.option, $0.title) },
                    isOn: { settings.suppressedCosmetics.contains($0) },
                    set: { option, isOn in
                        if isOn {
                            settings.suppressedCosmetics.insert(option)
                        } else {
                            settings.suppressedCosmetics.remove(option)
                        }
                    }
                )
                CardDivider()
                SettingsToggle(
                    title: "Hide my own too",
                    help: "Hides the ones you wear as well.",
                    isOn: $settings.suppressesOwnCosmetics
                )
            }
        }
    }

    // MARK: Readability

    private var readability: some View {
        SettingsGroup("Readability") {
            SettingsCard {
                SettingsToggle(
                    title: "Underline links",
                    help: "Links get an underline, not just a colour.",
                    isOn: $settings.underlinesLinks
                )
                CardDivider()
                SettingsFlyoutRow(
                    "Role colours",
                    help: "Names in the colour of their highest coloured role, or plain.",
                    selection: $settings.roleColorPlacement,
                    options: RoleColorPlacement.allCases,
                    title: \.title,
                    symbol: \.symbolName
                )
                CardDivider()
                SettingsSliderRow(
                    title: "Colour strength",
                    help: "How strongly role colours and name gradients show. At 0% they turn grey.",
                    value: $settings.userColorSaturation,
                    range: 0...1,
                    step: 0.05,
                    format: { "\(Int($0 * 100))%" }
                )
            }
            SettingsFootnote(
                "Looking for text size or density? They\u{2019}re in Appearance.",
                symbolName: "textformat.size"
            )
        }
    }

    // MARK: VoiceOver

    private var voiceOver: some View {
        SettingsGroup("VoiceOver") {
            SettingsCard {
                CardHeaderRow(
                    title: "Say this about a message",
                    help: "What VoiceOver reads out with each message. Fewer is quicker."
                )
                SettingsCheckboxGrid(
                    options: SpokenDetail.allCases.map { .init($0, $0.title) },
                    // Stored as the MUTED set, drawn as the spoken one — an
                    // opt-out list, so a detail added later is spoken for
                    // everybody rather than left out of a stored list of
                    // opt-ins nobody goes back to tick.
                    isOn: { !settings.mutedSpokenDetails.contains(.mask(for: $0)) },
                    set: { detail, isOn in
                        let mask = SpokenDetail.Set.mask(for: detail)
                        if isOn {
                            settings.mutedSpokenDetails.remove(mask)
                        } else {
                            settings.mutedSpokenDetails.insert(mask)
                        }
                    }
                )
                CardDivider()
                SettingsToggle(
                    title: "Announce new messages",
                    help: "VoiceOver reads new messages in the channel you\u{2019}re in as they arrive, "
                        + "cutting in on whatever it\u{2019}s saying.",
                    isOn: $settings.announcesNewMessages
                )
            }
        }
    }

    // MARK: What macOS decides

    private var systemSettings: some View {
        SettingsGroup("From macOS") {
            SettingsCard {
                SettingsValueRow(
                    title: "Reduce Motion",
                    value: reduceMotion ? "On" : "Off",
                    help: reduceMotion
                        ? "Movement becomes a quick fade."
                        : "Animations run in full."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Reduce Transparency",
                    value: reduceTransparency ? "On" : "Off",
                    help: reduceTransparency
                        ? "Solid surfaces instead of glass."
                        : "Glass, with your desktop showing through."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Increase Contrast",
                    value: contrast == .increased ? "On" : "Off",
                    help: "Text and edges get stronger while it\u{2019}s on."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Differentiate Without Color",
                    value: differentiateWithoutColor ? "On" : "Off",
                    help: "Every status has its own shape too, so colour is never the only clue."
                )
            }

            SettingsCard {
                SettingsNavigationRow(
                    title: "Display",
                    subtitle: "Motion, transparency and contrast.",
                    symbolName: "eye.fill",
                    tint: Color(hex: 0x0A84FF)
                ) {
                    open("x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")
                }
                CardDivider()
                SettingsNavigationRow(
                    title: "VoiceOver",
                    subtitle: "Your Mac reads the screen aloud.",
                    symbolName: "speaker.wave.3.fill",
                    tint: Color(hex: 0x5E5CE6)
                ) {
                    open("x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_VoiceOver")
                }
            }
        }
    }

    // MARK: Reset

    private var reset: some View {
        SettingsGroup {
            SettingsCard {
                SettingsActionRow(
                    "Reset this page",
                    help: "Puts this page back the way it started.",
                    actionTitle: "Reset"
                ) { isConfirmingReset = true }
            }
            // **A confirmation, because there is no undo.** §5.5's rule about a
            // destructive act: this throws away a set of choices somebody made
            // deliberately, and a misclick has nothing to put them back.
            .modal(isPresented: $isConfirmingReset, style: .alert) {
                ModalAlert(
                    hero: .symbol("arrow.counterclockwise"),
                    title: "Reset accessibility settings?",
                    message: Text("Every switch on this page goes back to its default. "
                        + "Nothing else in Settings changes."),
                    actions: [
                        .cancel(),
                        .act("Reset", symbol: "arrow.counterclockwise", irreversible: true, perform: resetAll),
                    ]
                )
            }
        }
    }

    private func resetAll() {
        settings.suppressedCosmetics = []
        settings.suppressesOwnCosmetics = false
        settings.underlinesLinks = false
        settings.roleColorPlacement = .inNames
        settings.userColorSaturation = 1
        settings.mutedSpokenDetails = []
        settings.announcesNewMessages = false
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        // The shortcuts registered with the whole machine. They are first
        // because they are the ones that can take a combination away from
        // another application, which is the only thing on this page with a cost
        // outside Wingcord.
        SettingsGroup("Anywhere on this Mac") {
            SettingsCard {
                ForEach(Array(GlobalAction.allCases.enumerated()), id: \.element.id) { entry in
                    if entry.offset > 0 { CardDivider() }
                    HotkeyRecorderRow(
                        title: entry.element.title,
                        help: entry.element.help,
                        hotkey: Binding(
                            get: { settings.hotkey(for: entry.element) },
                            set: { settings.setHotkey($0, for: entry.element) }
                        )
                    )
                }
            }
            SettingsFootnote(
                "These work even while you\u{2019}re in another app — and take their keys from it.",
                symbolName: "globe"
            )
        }

        // **Every one of these is a real menu item**, and the binding here is
        // the one the menu reads — see `AppShortcut`. A row that printed a key
        // the menu did not honour would be a lie in a settings window.
        ForEach(AppShortcut.Group.allCases) { group in
            SettingsGroup(group.title) {
                SettingsCard {
                    ForEach(
                        Array(AppShortcut.allCases.filter { $0.group == group }.enumerated()),
                        id: \.element.id
                    ) { entry in
                        if entry.offset > 0 { CardDivider() }
                        HotkeyRecorderRow(
                            title: entry.element.title,
                            help: conflictNote(for: entry.element),
                            hotkey: Binding(
                                get: { settings.shortcut(for: entry.element) },
                                set: { settings.setShortcut($0, for: entry.element) }
                            )
                        )
                    }
                }
            }
        }

        SettingsFootnote(
            "Click a shortcut and press the new keys. \u{232B} clears it \u{2014} the command stays in the menu bar.",
            symbolName: "keyboard"
        )

        // The keys the app answers on a view rather than in a menu. They are
        // **not** rebindable and the page says so rather than leaving a reader
        // hunting for the row: Return in a composer is the composer's grammar,
        // and a client that let it be moved would have a text field whose
        // meaning depends on a setting three panes away.
        SettingsGroup("Fixed") {
            SettingsCard {
                ForEach(SettingsShortcut.fixed.indices, id: \.self) { index in
                    let shortcut = SettingsShortcut.fixed[index]
                    if index > 0 { CardDivider() }
                    SettingsControlRow(shortcut.action) {
                        Text(shortcut.keys)
                            .font(SettingsType.rowLabel.monospaced())
                            .foregroundStyle(Ink.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Says so when two rows share a combination.
    ///
    /// **A collision is a real defect and a silent one**: AppKit gives the
    /// combination to whichever menu item it finds first and the other command
    /// simply stops working, with nothing on screen to say why.
    private func conflictNote(for shortcut: AppShortcut) -> String? {
        guard let binding = settings.shortcut(for: shortcut) else { return nil }
        let clashes = settings.shortcutConflicts(binding, ignoring: shortcut)
        guard !clashes.isEmpty else { return nil }
        return "Also bound to \(clashes.map(\.title).joined(separator: ", "))."
    }
}

// MARK: - Storage

private struct StoragePane: View {
    /// Bytes on disk, or nil until the first measurement lands.
    ///
    /// **Measured on appear and after a clear, never on a timer.** The download
    /// cache's figure is a property read, but the folder sizes mean walking a
    /// directory — and a settings pane that walked two directories once a second
    /// would spend more on reporting the cost than the cost it reports.
    @State private var report: StorageReport?

    var body: some View {
        // The memory half lives in Performance › Now, beside the footprint it
        // is part of; this is what stays on the disk. The report folder is
        // Diagnostics', with the trace it holds.
        SettingsCard {
            SettingsMeterRow(
                title: "Downloaded images",
                help: "Avatars, attachments and artwork kept on disk, so nothing downloads twice.",
                used: report?.downloadCache ?? 0,
                capacity: ImageStore.shared.downloadCacheCapacity
            )
            CardDivider()
            SettingsValueRow(
                title: "Crash reports and traces",
                value: report.map { SettingsMeterRow.bytes($0.reports) } ?? "—",
                help: "Saved on this Mac. Never sent anywhere."
            )
            CardDivider()
            SettingsActionRow(
                "Image cache folder",
                help: "~/Library/Caches, under Wingcord\u{2019}s bundle identifier.",
                actionTitle: "Reveal"
            ) {
                let directory = ImageStore.cacheDirectory
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        }

        SettingsGroup("Reclaim") {
            SettingsCard {
                SettingsActionRow(
                    "Downloaded images",
                    help: "Frees disk space. Pictures download again the next time you see them.",
                    actionTitle: "Empty"
                ) {
                    ImageStore.shared.clearDownloadCache()
                    measure(settling: true)
                }
                CardDivider()
                SettingsActionRow(
                    "Decoded images and animations",
                    help: "Frees memory. Pictures come back from the disk, not the network.",
                    actionTitle: "Free"
                ) {
                    ImageStore.shared.purge()
                    AnimatedImageStore.shared.purge()
                    FilmFrames.shared.purge()
                    LottieDocuments.shared.purge()
                    measure(settling: false)
                }
            }
        }
        .task { await refresh() }
    }

    /// Re-reads the figures.
    ///
    /// **`settling` exists because `removeAllCachedResponses()` returns before
    /// the files are gone.** Measured: the folder still read 552 kB immediately
    /// after the call and 168 kB three seconds later, so a single measurement
    /// taken at the click reports the size the reader just asked to be rid of —
    /// and the button looks broken. Deleting the directory by hand instead would
    /// be faster and would corrupt `URLCache`'s own index, so the answer is to
    /// ask twice: once now, so the pane responds, and once after the deletion has
    /// landed, so it ends up right.
    private func measure(settling: Bool) {
        Task {
            await refresh()
            guard settling else { return }
            try? await Task.sleep(for: .milliseconds(700))
            await refresh()
        }
    }

    private func refresh() async {
        report = await StorageReport.current()
    }
}

/// Everything the storage pane can honestly report, gathered once.
private struct StorageReport: Sendable {
    var downloadCache: Int
    var reports: Int

    @MainActor
    static func current() async -> StorageReport {
        let images = ImageStore.cacheDirectory
        let reports = CrashReporter.reportDirectory
        // Both figures come from walking the directories, off the main actor:
        // walking is I/O and a settings pane must not do it on the thread that
        // draws.
        //
        // **Not `URLCache.currentDiskUsage`.** It is a property read and would be
        // cheaper, but it lags its own `removeAllCachedResponses()` — measured:
        // the folder had gone from 5.7 MB to 168 kB and the property still
        // answered 5.5 MB, so the Empty button appeared to do nothing. The
        // directory is the number Finder shows and the one the reader is
        // reclaiming.
        let sizes = await Task.detached(priority: .utility) {
            (cache: StorageReport.size(of: images), reports: StorageReport.size(of: reports))
        }.value
        return StorageReport(
            downloadCache: sizes.cache, reports: sizes.reports
        )
    }

    /// Bytes on disk under a directory.
    ///
    /// `allocatedSizeOnDisk` rather than `fileSize`: a hundred short log files
    /// occupy a hundred blocks whatever their contents say, and the number this
    /// pane exists to give is the one that comes back when you delete them.
    nonisolated static func size(of directory: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            total += values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
        }
        return total
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsCard {
            SettingsValueRow(
                title: "Connection",
                value: model.connectionState.settingsLabel,
                help: "Your live connection to Discord."
            )
            CardDivider()
            SettingsValueRow(title: "Servers", value: "\(model.guilds.count)")
            CardDivider()
            SettingsValueRow(title: "People known", value: "\(model.users.count)")
            CardDivider()
            SettingsValueRow(title: "Folders", value: "\(model.folders.count)")
        }

        SettingsGroup("Logging") {
            SettingsCard {
                SettingsValueRow(
                    title: "Session trace",
                    value: DiagnosticLog.isEnabled ? "Recording" : "Off",
                    help: "Turn on with: defaults write dev.wingcord.Wingcord traceSession -bool YES"
                )
                CardDivider()
                SettingsActionRow(
                    "Report folder",
                    help: "Crash reports and the session trace are written here.",
                    actionTitle: "Reveal"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([CrashReporter.reportDirectory])
                }
            }
            SettingsFootnote(
                "The trace writes down every step a connection takes, so one that never comes up can be pinned down.",
                symbolName: "waveform.path.ecg"
            )
        }
    }
}

private extension AppModel.ConnectionState {
    /// Said in words rather than as a case name. `failed` carries its reason,
    /// because "Failed" on its own is a state nobody can act on.
    var settingsLabel: String {
        switch self {
        case .signedOut: "Signed out"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .reconnecting: "Reconnecting…"
        case .failed(let reason): "Failed — \(reason)"
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsHero(
            symbolName: "bubble.left.and.bubble.right.fill",
            tint: Color(hex: 0x5865F2),
            title: "Wingcord",
            subtitle: "A native macOS client for Discord"
        )

        SettingsCard {
            SettingsValueRow(title: "Version", value: Bundle.main.shortVersion)
            CardDivider()
            SettingsValueRow(title: "Build", value: Bundle.main.buildVersion)
        }

        SettingsGroup("Project") {
            SettingsTileRow(tiles: [
                .init(
                    id: "source", title: "Source",
                    caption: "The code that draws this window",
                    symbolName: "chevron.left.forwardslash.chevron.right"
                ) { open("https://github.com/wingcord/wingcord") },
                .init(
                    id: "licence", title: "Licence",
                    caption: "How you may use it",
                    symbolName: "doc.text"
                ) { open("https://github.com/wingcord/wingcord/blob/main/LICENSE") },
                .init(
                    id: "lottie", title: "Lottie",
                    caption: "Plays Discord\u{2019}s animated stickers",
                    symbolName: "heart.fill"
                ) { open("https://github.com/airbnb/lottie-ios") },
            ])
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        openURL(url)
    }
}

// MARK: - Bundle

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var buildVersion: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
