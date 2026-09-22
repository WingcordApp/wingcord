import AppKit
import SwiftUI
import WingcordCore

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
        VStack(alignment: .leading, spacing: 0) {
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
            case .general: GeneralPane()
            case .appearance: AppearancePane()
            case .messages: MessagesPane()
            case .expressions: ExpressionsPane()
            case .media: MediaPane()
            case .voiceVideo: VoiceVideoPane()
            case .notifications: NotificationsPane()
            case .activity: ActivityPane()
            case .overlay: OverlayPane()
            case .clips: ClipsPane()
            case .account: AccountPane()
            case .connectedApps: ConnectedAppsPane()
            case .privacy: PrivacyPane()
            case .performance: PerformancePane()
            case .accessibility: AccessibilityPane()
            case .shortcuts: ShortcutsPane()
            case .storage: StoragePane()
            case .diagnostics: DiagnosticsPane()
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
        }

        SettingsGroup("Appearance and access") {
            SettingsCard {
                SettingsNavigationRow(
                    title: "Appearance",
                    subtitle: "Themes, a background picture, text size and density.",
                    symbolName: SettingsSection.appearance.symbolName,
                    tint: SettingsSection.appearance.tint
                ) { navigate(.appearance) }
                CardDivider()
                SettingsNavigationRow(
                    title: "Permissions",
                    subtitle: "Notifications and system access, granted by macOS.",
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
                    help: "A new window opens with the roster column showing. The toolbar toggle still overrides it per conversation.",
                    isOn: $settings.showsMemberListByDefault
                )
            }
        }

        SettingsGroup("Advanced") {
            SettingsCard {
                SettingsToggle(
                    title: "Developer mode",
                    help: "Adds Copy Message ID and Copy User ID to the menus that have an id to copy. Nothing else changes.",
                    isOn: $settings.developerMode
                )
            }
            SettingsFootnote(
                "The items are absent rather than greyed out when this is off — a menu a third longer for nobody's benefit is worse than a shorter one.",
                symbolName: "number"
            )
        }

        SettingsGroup("Language") {
            SettingsCard {
                SettingsActionRow(
                    "Language",
                    help: "Wingcord follows the system language for the whole interface.",
                    actionTitle: "System Settings"
                ) {
                    open("x-apple.systempreferences:com.apple.Localization-Settings.extension")
                }
            }
            SettingsFootnote(
                "Dates, times and number formats follow the same setting, which is why there is no separate control for them here.",
                symbolName: "globe"
            )
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @State private var settings = AppSettings.shared
    @State private var theme = ThemeStore.shared
    @Environment(\.motion) private var motion

    var body: some View {
        SettingsGroup("Theme") {
            ThemeGallery()
            SettingsFootnote(
                "A theme colours the ground the app is read on and the one accent it spends — "
                    + "never a role, an avatar or anything else that came from a person. Every "
                    + "one of them is built on the same three steps of lightness, so the "
                    + "separation between the reading surface, a card on it and a row inside "
                    + "that card is the same whichever you pick.",
                symbolName: "circle.lefthalf.filled"
            )
        }

        // Only while it is the theme in use. A picker for a blend nobody has
        // selected is a control whose every move is invisible — and it is a
        // hundred and fifty points of card standing between the gallery and the
        // picture.
        //
        // The group is always in the tree and its *contents* come and go, which
        // is what gives the animation something stable to run on: a conditional
        // wrapped around the group itself would be a structural change to the
        // pane, and the card would appear at full height with no transition at
        // all.
        SettingsGroup {
            if theme.choice.isCustom {
                PlumageCard()
                    .padding(.top, SettingsMetrics.cardToHeader)
                    .transition(.opacity)
            }
        }
        .animation(motion.standard, value: theme.choice.isCustom)

        SettingsGroup("Picture") {
            BackdropCard()
        }

        SettingsGroup("Preview") {
            SettingsMessagePreview()
            SettingsFootnote(
                "Drawn by the transcript's own painter, so it cannot disagree with the real thing.",
                symbolName: "eye"
            )
        }

        SettingsGroup("Bars") {
            SettingsCard {
                CardHeaderRow(
                    title: "Appearance",
                    help: "The silhouette both floating bars take. A pill keeps "
                        + "its round controls beside it; a boxy bar encloses them."
                )
                SettingsSegmentedControl(
                    selection: $settings.chromeShape,
                    options: ChromeShape.allCases.map {
                        .init($0, $0.label, symbolName: $0.symbolName)
                    }
                )
                CardDivider()
                SettingsChromePreview(
                    shape: settings.chromeShape,
                    controls: $settings.composerControls
                )
                CardDivider()
                SettingsToggle(
                    title: "Show my nameplate",
                    help: "Wears the nameplate on your account behind your name.",
                    isOn: $settings.showsNameplateInNowBar
                )
            }
            SettingsFootnote(
                "The real bars, at the shape above — not a picture of them. "
                    + "Drag the icons to rearrange them.",
                symbolName: "hand.draw"
            )
        }

        SettingsCard {
            CardHeaderRow(
                title: "Message density",
                help: "Compact removes the spacing between runs and shrinks the author gutter."
            )
            SettingsSegmentedControl(
                selection: $settings.isCompactMode,
                options: [
                    .init(false, "Comfortable", symbolName: "rectangle.expand.vertical"),
                    .init(true, "Compact", symbolName: "rectangle.compress.vertical"),
                ]
            )
        }
        .padding(.top, SettingsMetrics.cardToHeader)

        SettingsGroup("Text") {
            SettingsCard {
                SettingsSliderRow(
                    title: "Message size",
                    help: "Scales on top of the system text size, so the accessibility setting still applies.",
                    value: $settings.textScale,
                    range: 0.8...1.6,
                    step: 0.05,
                    format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                )
            }
            SettingsFootnote(
                "Every size in Wingcord is relative, so this scales the whole window rather than only the transcript.",
                symbolName: "textformat.size"
            )
        }

        SettingsGroup("Colour") {
            SettingsCard {
                SettingsSliderRow(
                    title: "User colour intensity",
                    help: "Applies to colour that came from people — role colours, "
                        + "profile themes — and never to Wingcord's own chrome.",
                    value: $settings.userColorSaturation,
                    range: 0...1,
                    step: 0.05,
                    format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                )
            }
            SettingsFootnote(
                "Hue and brightness are left alone, so a dark role stays dark and two "
                    + "colours you could tell apart still look different. At 0% every "
                    + "user colour becomes the grey of its own brightness.",
                symbolName: "paintpalette"
            )
        }

        SettingsGroup("Motion and transparency") {
            SettingsCard {
                SettingsNavigationRow(
                    title: "Accessibility",
                    subtitle: "Reduce Motion and Reduce Transparency.",
                    symbolName: "figure.walk.motion",
                    tint: Color(hex: 0x0A84FF)
                ) {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            // Deliberately NOT duplicated as an app toggle. Two switches for one
            // behaviour means a reader who set the system one and still sees
            // animation cannot tell which is being honoured — and honouring only
            // the app's is exactly how someone who set Reduce Motion in System
            // Settings gets the full animation set anyway.
            SettingsFootnote(
                "Wingcord follows both system settings. There is no app-level copy of either, so there is never a question of which one won.",
                symbolName: "info.circle"
            )
        }
    }
}

// MARK: - Messages

private struct MessagesPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            CardHeaderRow(title: "Timestamps", help: "How the time beside a message is written.")
            SettingsSegmentedControl(
                selection: $settings.uses24HourTime,
                options: [
                    .init(false, "12-hour", symbolName: "clock"),
                    .init(true, "24-hour", symbolName: "clock.badge.checkmark"),
                ]
            )
        }

        SettingsGroup("Content") {
            SettingsCard {
                SettingsToggle(
                    title: "Show link previews",
                    help: "Unfurl embeds for links posted in a conversation.",
                    isOn: $settings.showsEmbeds
                )
                CardDivider()
                SettingsToggle(
                    title: "Load images automatically",
                    help: "Turn this off to fetch attachments only when you open them.",
                    isOn: $settings.loadsImagesAutomatically
                )
            }
        }
    }
}

// MARK: - Expressions

private struct ExpressionsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            CardHeaderRow(title: "Default skin tone", help: "Applied to every emoji that takes one.")
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
        }

        SettingsGroup("Playback") {
            SettingsCard {
                SettingsToggle(
                    title: "Play animated emoji and avatars",
                    help: "An animated emoji is a decode loop for as long as it is on screen.",
                    isOn: $settings.playsAnimatedContent
                )
            }
            SettingsFootnote(
                "Turning animation off saves real power on battery: a busy channel can hold a dozen decode loops at once.",
                symbolName: "battery.75percent"
            )
        }
    }
}

// MARK: - Media

private struct MediaPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            SettingsSliderRow(
                title: "Playback volume",
                help: "Shared by every clip the viewer opens.",
                value: $settings.mediaVolume,
                range: 0...1,
                step: 0.05,
                format: { $0.formatted(.percent.precision(.fractionLength(0))) }
            )
            CardDivider()
            SettingsToggle(
                title: "Start muted",
                help: "Kept apart from a zero volume, so unmuting restores the level you set.",
                isOn: $settings.mutesMedia
            )
            CardDivider()
            SettingsToggle(
                title: "Loop videos",
                help: "Repeat a clip when it reaches the end.",
                isOn: $settings.loopsVideo
            )
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Show unread counts",
                help: "In the server rail and on the Dock icon. The unread dot stays either way — this is the number.",
                isOn: $settings.showsUnreadCounts
            )
        }
        SettingsFootnote(
            "Muted conversations never contribute to a count, and a channel you cannot see never marks its server unread.",
            symbolName: "bell.slash"
        )

        SettingsGroup("Banners") {
            SettingsCard {
                SettingsToggle(
                    title: "Show notifications",
                    help: "A banner when a message arrives in a channel you are not reading.",
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
                "Each server's own notification setting is honoured, and a muted server or channel never notifies. "
                    + "Direct messages always do, unless you have muted the conversation.",
                symbolName: "bell.badge"
            )
            SettingsFootnote(
                "macOS decides whether Wingcord may interrupt you at all. If nothing appears, look under "
                    + "Notifications in System Settings.",
                symbolName: "gear"
            )
        }
    }
}

// MARK: - Account

private struct AccountPane: View {
    @Environment(AppModel.self) private var model
    @State private var accounts: [StoredAccount] = []

    var body: some View {
        if let userID = model.currentUserID, let user = model.users[userID] {
            SettingsHero(title: user.preferredName, subtitle: user.handle) {
                AvatarView(
                    url: model.avatarURL(for: user, side: 64),
                    monogram: user.monogram,
                    side: 64
                )
            }
            SettingsCard {
                SettingsValueRow(title: "Account", value: user.handle)
                CardDivider()
                SettingsValueRow(title: "Session", value: "Signed in on this Mac")
            }
        } else {
            SettingsCard {
                SettingsValueRow(
                    title: "Account",
                    value: "Not signed in",
                    help: "Sign in from the main window."
                )
            }
        }

        SettingsGroup("Standing") {
            AccountStandingCard(standing: model.accountStanding)
        }
        .task { model.sessionController.loadAccountStanding() }

        SettingsGroup("Other accounts on this Mac") {
            SettingsCard {
                let others = accounts.filter { $0.id != model.currentUserID?.description }
                if others.isEmpty {
                    SettingsValueRow(title: "Stored accounts", value: "None")
                } else {
                    ForEach(others.indices, id: \.self) { index in
                        let account = others[index]
                        if index > 0 { CardDivider() }
                        SettingsActionRow(
                            account.preferredName,
                            actionTitle: "Switch"
                        ) {
                            model.resumeSession(for: account)
                        }
                    }
                }
            }
            SettingsFootnote(
                "Tokens live in the macOS Keychain, marked so they never sync to iCloud and are unreadable while the Mac is locked.",
                symbolName: "key.fill"
            )
        }
        .task { accounts = AccountLedger.accounts() }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    var body: some View {
        SettingsCard {
            SettingsValueRow(
                title: "Analytics",
                value: "None collected",
                help: "Wingcord has no telemetry of any kind and makes no request that is not to Discord."
            )
            CardDivider()
            SettingsValueRow(
                title: "Crash reports",
                value: "Local only",
                help: "Written beside the app's own data and never sent anywhere."
            )
        }

        SettingsGroup("Terms") {
            SettingsCard {
                SettingsValueRow(title: "Client", value: "Third-party")
                CardDivider()
                SettingsValueRow(title: "Affiliation", value: "None")
            }
            SettingsFootnote(
                "Wingcord is not affiliated with Discord. Using a third-party client is against Discord's terms of service; use it knowing that.",
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
                help: "A live overlay: frame time, memory, cache occupancy. It costs nothing while it is off.",
                isOn: $settings.showsPerformanceInspector
            )
        }

        SettingsGroup("Now") {
            SettingsCard {
                SettingsValueRow(title: "Memory footprint", value: snapshot.footprintDescription)
                CardDivider()
                SettingsValueRow(title: "Image cache budget", value: snapshot.imageBudgetDescription)
                CardDivider()
                SettingsValueRow(title: "Loaded transcripts", value: "\(snapshot.residentChannels)")
                CardDivider()
                SettingsValueRow(title: "Messages held", value: "\(snapshot.residentMessages)")
                CardDivider()
                SettingsValueRow(title: "Slow frames (last 300)", value: "\(snapshot.slowFrames)")
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
                        help: "The worst of the last 300. One slow frame is a hitch; a rising worst is a regression."
                    )
                    CardDivider()
                    SettingsValueRow(
                        title: "Display",
                        value: snapshot.displayHertz.formatted(
                            .number.precision(.fractionLength(0))
                        ) + " Hz",
                        help: "What a frame has to fit inside. At 120 Hz that is 8.3 ms."
                    )
                }
            }
        }

        SettingsGroup("Maintenance") {
            SettingsCard {
                SettingsActionRow(
                    "Cached images",
                    help: "Images come back from the on-disk cache, so this frees memory without costing a download.",
                    actionTitle: "Free"
                ) {
                    ImageStore.shared.purge()
                    snapshot = PerformanceMonitor.shared.snapshot()
                }
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
    }

    private func milliseconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ms"
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

    var body: some View {
        SettingsCard {
            SettingsValueRow(
                title: "Reduce Motion",
                value: reduceMotion ? "On" : "Off",
                help: reduceMotion
                    ? "Travel is replaced by a short cross-fade. The materials stay."
                    : "Animations run in full. Wingcord has no separate motion setting."
            )
            CardDivider()
            SettingsValueRow(
                title: "Reduce Transparency",
                value: reduceTransparency ? "On" : "Off",
                help: reduceTransparency
                    ? "This window is drawn on opaque surfaces instead of glass."
                    : "Chrome is glass, and the desktop shows through it."
            )
            CardDivider()
            SettingsValueRow(
                title: "Increase Contrast",
                value: contrast == .increased ? "On" : "Off",
                help: "Every label uses the system's hierarchy rather than a fixed grey, so contrast tracks this automatically."
            )
            CardDivider()
            SettingsValueRow(
                title: "Differentiate Without Color",
                value: differentiateWithoutColor ? "On" : "Off",
                help: "Presence is drawn as a shape — filled, crescent, dash, ring — and not by colour alone, whether or not this is set."
            )
        }
        SettingsFootnote(
            "Reported, not duplicated: there is no app-level copy of any of these, so there is never a question of which one is being honoured.",
            symbolName: "checkmark.seal"
        )

        SettingsGroup("Text size") {
            SettingsCard {
                SettingsValueRow(
                    title: "System text size",
                    value: "Followed",
                    help: "Every size in the app is a relative style, so the accessibility text setting scales all of it."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Wingcord's own scale",
                    value: settings.textScale.formatted(.percent.precision(.fractionLength(0))),
                    help: "Applied on top of the system size, never instead of it."
                )
            }
        }

        SettingsGroup("Change these") {
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
                    subtitle: "Every row in this window carries a spoken label.",
                    symbolName: "speaker.wave.3.fill",
                    tint: Color(hex: 0x5E5CE6)
                ) {
                    open("x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_VoiceOver")
                }
            }
        }
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
        // The shortcuts on this page that are not menu items, and the only ones
        // the reader can change: they are registered with the whole machine,
        // not with this app's responder chain, so they are controls rather than
        // lines in the table below.
        SettingsCard {
            ForEach(Array(GlobalAction.allCases.enumerated()), id: \.element.id) { index, action in
                if index > 0 { CardDivider() }
                HotkeyRecorderRow(
                    title: action.title,
                    help: action.help,
                    hotkey: Binding(
                        get: { settings.hotkey(for: action) },
                        set: { settings.setHotkey($0, for: action) }
                    )
                )
            }
        }
        SettingsFootnote(
            "A global shortcut takes its combination away from every other application, which is why there are only a few and why each can be cleared with ⌫ while recording.",
            symbolName: "globe"
        )

        // No `ForEach` over the groups with an index: each carries its own
        // heading, and a `SettingsGroup` per group is what gives the 20/16/10
        // rhythm the rest of the window has.
        ForEach(SettingsShortcut.groups, id: \.title) { group in
            SettingsGroup(group.title) {
                SettingsCard {
                    ForEach(group.shortcuts.indices, id: \.self) { index in
                        let shortcut = group.shortcuts[index]
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

        SettingsFootnote(
            "Every one of these is bound in the menu bar or on the view that handles it — nothing is listed here that the app does not actually do.",
            symbolName: "keyboard"
        )
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
        SettingsCard {
            SettingsMeterRow(
                title: "Downloaded images",
                help: "Avatars, attachments and artwork, kept so a relaunch is cheap and a re-decode is a decode rather than a download.",
                used: report?.downloadCache ?? 0,
                capacity: ImageStore.shared.downloadCacheCapacity
            )
        }
        SettingsFootnote(
            "This is the disk half. It is deliberately outside the memory budget below — 512 MB of cached bytes is not 512 MB of memory.",
            symbolName: "internaldrive"
        )

        SettingsGroup("In memory") {
            SettingsCard {
                SettingsValueRow(
                    title: "Decoded image budget",
                    value: SettingsMeterRow.bytes(ImageStore.shared.residentBudget),
                    help: "What the three image caches may hold between them: avatars 48 MB, attachments 32 MB, artwork 16 MB."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Animation budget",
                    value: SettingsMeterRow.bytes(AnimatedImageStore.budget),
                    help: "Filmstrips for animated emoji, avatar decorations and profile effects. A sixty-frame decoration is about 2 MB."
                )
                CardDivider()
                SettingsValueRow(
                    title: "Process footprint",
                    value: report.map { SettingsMeterRow.bytes(Int($0.footprint)) } ?? "—",
                    help: "phys_footprint — what Activity Monitor shows and what a jetsam decision is made on."
                )
            }
            // What a cache is ALLOWED, not what it holds: `NSCache` publishes its
            // cost limit and never its current cost, and a figure derived by
            // walking the keys would be a guess dressed as a measurement.
            SettingsFootnote(
                "Budgets, not occupancy: the caches report what they may hold and never what they are holding, so this pane does not claim to know.",
                symbolName: "questionmark.circle"
            )
        }

        SettingsGroup("Diagnostics on disk") {
            SettingsCard {
                SettingsValueRow(
                    title: "Crash reports and traces",
                    value: report.map { SettingsMeterRow.bytes($0.reports) } ?? "—",
                    help: "Written beside the app's own data, and never sent anywhere."
                )
                CardDivider()
                SettingsActionRow(
                    "Report folder",
                    actionTitle: "Reveal"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([CrashReporter.reportDirectory])
                }
                CardDivider()
                SettingsActionRow(
                    "Image cache folder",
                    help: "~/Library/Caches, under the app's bundle identifier.",
                    actionTitle: "Reveal"
                ) {
                    let directory = ImageStore.cacheDirectory
                    try? FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }
        }

        SettingsGroup("Reclaim") {
            SettingsCard {
                SettingsActionRow(
                    "Downloaded images",
                    help: "Frees disk. Everything still on screen is re-downloaded the next time it is needed.",
                    actionTitle: "Empty"
                ) {
                    ImageStore.shared.clearDownloadCache()
                    measure(settling: true)
                }
                CardDivider()
                SettingsActionRow(
                    "Decoded images and animations",
                    help: "Frees memory without costing a download — the bytes come back from the disk cache above.",
                    actionTitle: "Free"
                ) {
                    ImageStore.shared.purge()
                    AnimatedImageStore.shared.purge()
                    measure(settling: false)
                }
            }
            SettingsFootnote(
                "Emptying the disk cache costs a download; freeing memory costs a decode. Under memory pressure the app already does the second one by itself.",
                symbolName: "arrow.clockwise"
            )
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
    var footprint: UInt64

    @MainActor
    static func current() async -> StorageReport {
        let footprint = PerformanceMonitor.physicalFootprint()
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
            downloadCache: sizes.cache, reports: sizes.reports, footprint: footprint
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
                help: "The gateway socket's state, live."
            )
            CardDivider()
            SettingsValueRow(title: "Servers", value: "\(model.guilds.count)")
            CardDivider()
            SettingsValueRow(title: "People known", value: "\(model.users.count)")
            CardDivider()
            SettingsValueRow(
                title: "Folders",
                value: "\(model.folders.count)",
                help: "Read from user_settings_proto, which is where Discord keeps them now."
            )
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
                "The trace records the ORDER of the events a connection goes through — the gateway's handshake, and the nine messages a call's encryption is negotiated in. Reading that order is how a connection that never comes up gets diagnosed; the lines alone do not say where the time went.",
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
                    caption: "The one dependency, and why",
                    symbolName: "heart.fill"
                ) { open("https://github.com/airbnb/lottie-ios") },
            ])
            SettingsFootnote(
                "Eight of Discord's fourteen sticker packs are Lottie, and a Lottie sticker has no bitmap on the CDN at all — both the .png and .gif endpoints answer 404. It is used only as a rasteriser, at load time, off the main thread.",
                symbolName: "shippingbox"
            )
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
