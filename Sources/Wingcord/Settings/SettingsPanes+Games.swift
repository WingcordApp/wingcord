import AppKit
import SwiftUI
import WingcordCore
import WingcordNet

// MARK: - Activity, the overlay, and clips
//
// Three panes in one group, mirroring where Discord puts them — Registered
// Games, Activity Privacy and Game Overlay under one heading. They are folded
// into three panes rather than four because a source list of twenty rows is a
// source list nobody can scan, and because "what you are playing" and "who sees
// it" are one question asked twice.
//
// Built from the vocabulary in `SettingsRows.swift` and nothing else.

// MARK: - Activity

struct ActivityPane: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    private var privacy: ActivityPrivacy { model.activityPrivacy }

    /// docs/CLIPS-PRESENCE.md, D22: what goes out now, then each source of it —
    /// what plays, games, connected apps — then who sees it.
    var body: some View {
        BroadcastPreviewGroup()
        NowPlayingSettingsGroup()
        runningGame
        RegisteredGamesGroup()
        GameModeSettingsGroup()
        GameEventsSettingsGroup()
        ConnectedRPCAppsGroup()
        sharing
        whereShared
        joining
    }

    // MARK: What is running

    private var runningGame: some View {
        SettingsGroup("Games") {
            runningGameCard
        }
    }

    @ViewBuilder private var runningGameCard: some View {
        SettingsCard {
            if let game = model.detectedGame {
                SettingsControlRow(game.name, help: detectionHelp(for: game)) {
                    Text(privacy.sharesCurrentGame ? "Sharing" : "Hidden")
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(
                            privacy.sharesCurrentGame
                                ? AnyShapeStyle(Palette.presenceOnline)
                                : AnyShapeStyle(Ink.secondary)
                        )
                }
            } else if let running = model.sessionController.games.runningGame {
                // Running, and switched off in Registered Games: named here so
                // the reader can find the switch, and nowhere else.
                SettingsValueRow(
                    title: running.name,
                    value: "Detection off",
                    help: "Switched off in Registered Games below, so it isn\u{2019}t shown."
                )
            } else {
                SettingsValueRow(
                    title: "Nothing detected",
                    value: "—",
                    help: "Start a game and it shows up here. Wingcord sees which apps are open, "
                        + "never what\u{2019}s in them."
                )
            }
        }
    }

    private func detectionHelp(for game: DetectedGame) -> String {
        var parts: [String] = []
        if game.isTranslated { parts.append("running through a Windows translation layer") }
        if game.isLauncher { parts.append("this is the launcher rather than the game") }
        parts.append("started \(game.startedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: ", ").localizedCapitalized
    }

    // MARK: What is shared

    private var sharing: some View {
        SettingsGroup("What I share") {
            SettingsCard {
                SettingsToggle(
                    title: "Share my activity",
                    help: "Friends and servers see what you\u{2019}re playing. It follows your account, "
                        + "so it\u{2019}s the same everywhere you\u{2019}re signed in.",
                    isOn: Binding(
                        get: { privacy.sharesCurrentGame },
                        set: { model.setSharesCurrentGame($0) }
                    )
                )
            }
        }
    }

    // MARK: Where

    private var whereShared: some View {
        SettingsGroup("Where I share it") {
            SettingsCard {
                ForEach(Array(scopeOptions.enumerated()), id: \.element) { index, scope in
                    if index > 0 { CardDivider() }
                    // **The whole row, not the fifteen-point circle.** A radio
                    // whose target is only its own glyph is a radio people miss,
                    // and every other row in this window is clickable across its
                    // full width.
                    Button {
                        model.applyActivityPrivacy(.sharingScope(scope))
                    } label: {
                        SettingsControlRow(scope.title) {
                            Image(symbol: isSelected(scope)
                                ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(
                                    isSelected(scope)
                                        ? AnyShapeStyle(Palette.accent)
                                        : AnyShapeStyle(Ink.tertiary)
                                )
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(scope.title)
                    .accessibilityAddTraits(isSelected(scope) ? [.isSelected] : [])
                }
            }
            .disabled(!privacy.sharesCurrentGame)
            SettingsFootnote(
                privacy.sharesCurrentGame
                    ? "Friends always see it. A small server has 200 members or fewer."
                    : "Turn on Share my activity to choose.",
                symbolName: privacy.sharesCurrentGame ? "person.2" : "exclamationmark.triangle"
            )
        }
    }

    /// The three the reader can pick.
    ///
    /// `.unset` is a real wire value but not an answer anybody gives: it means
    /// the account has never been asked, and it behaves as "share everywhere".
    private var scopeOptions: [ActivitySharingScope] {
        [.everywhere, .smallServersOnly, .friendsOnly]
    }

    private func isSelected(_ scope: ActivitySharingScope) -> Bool {
        if privacy.sharingScope == .unset { return scope == .everywhere }
        return privacy.sharingScope == scope
    }

    // MARK: Who can join

    private var joining: some View {
        SettingsGroup("Who can join my games") {
            SettingsCard {
                SettingsToggle(
                    title: "Friends",
                    help: "Lets a friend join your game without asking first.",
                    isOn: Binding(
                        get: { privacy.allowsFriendsToJoin },
                        set: { model.applyActivityPrivacy(.friendsJoin($0)) }
                    )
                )
                CardDivider()
                SettingsToggle(
                    title: "Anyone in the same voice channel",
                    help: "Only works in servers that are not Community-enabled.",
                    isOn: Binding(
                        get: { privacy.allowsVoiceParticipantsToJoin },
                        set: { model.applyActivityPrivacy(.voiceJoin($0)) }
                    )
                )
            }
            SettingsFootnote(
                "Some games let people join straight from your activity. These decide who has to ask.",
                symbolName: "person.badge.plus"
            )
        }
    }
}

/// The "Add it!" picker — everything running, by process.
///
/// **Running processes, not an app chooser.** Discord's own picker lists
/// `getCandidateGames()`, which is the set of running processes keyed by pid,
/// and that is what makes it possible to add the thing you are looking at
/// rather than hunting for its bundle in `/Applications`.
struct AddGameRow: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    @State private var isPicking = false

    var body: some View {
        SettingsCard {
            // Discord's words.
            SettingsControlRow(
                "Not seeing your game?",
                help: "Add anything that\u{2019}s open and has a window \u{2014} even an app "
                    + "that isn\u{2019}t a game."
            ) {
                Button("Add it!") { isPicking = true }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                        candidateList
                    }
            }
        }
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.sessionController.games.candidates) { candidate in
                    Button {
                        add(candidate)
                    } label: {
                        HStack(spacing: Spacing.base) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.executableURL.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(candidate.name)
                                .font(SettingsType.rowTitle)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.snug)
                        .frame(height: 28)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Spacing.base)
        }
        .frame(width: 260, height: 260)
    }

    private func add(_ candidate: GameDetector.RunningCandidate) {
        isPicking = false
        // A synthetic id: this application is not in Discord's database and has
        // no snowflake. Derived from the path so the same executable added
        // twice is the same entry, and high enough not to collide with a real
        // application id.
        let id = ApplicationID(
            rawValue: RegisteredGamesStore.manualID(forExecutableAt: candidate.executableURL.path)
        )
        settings.addManualGame(name: candidate.name, path: candidate.executableURL.path, id: id)
        RegisteredGamesStore.shared.add(id: id.rawValue, name: candidate.name)
        model.sessionController.games.addManualGame(
            GameDetector.DetectedGameOverride(id: id, name: candidate.name),
            forExecutableAt: candidate.executableURL.path
        )
    }
}

// MARK: - Game Overlay

struct OverlayPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsNavigate) private var navigate
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Show the overlay over games",
                help: "Your friends and messages, floating over whatever you\u{2019}re playing. "
                    + "Nothing touches the game itself.",
                isOn: $settings.isOverlayEnabled
            )
        }
        SettingsFootnote(
            "Works over windowed and borderless games. One that takes over the whole display covers it.",
            symbolName: "macwindow.on.rectangle"
        )

        SettingsGroup("Keys") {
            SettingsCard {
                SettingsNavigationRow(
                    title: "Overlay shortcuts",
                    subtitle: keySummary,
                    symbolName: "keyboard",
                    tint: SettingsSection.shortcuts.tint
                ) { navigate(.shortcuts) }
            }
            SettingsFootnote(
                "Esc or a click outside closes it. Hold \u{2325} to hide every widget.",
                symbolName: "escape"
            )
        }

        SettingsGroup("While you\u{2019}re playing") {
            SettingsCard {
                SettingsToggle(
                    title: "Let pinned widgets be clicked",
                    help: "Pinned widgets answer clicks while you play. Handy for muting, "
                        + "awkward under a crosshair.",
                    isOn: $settings.overlayHasClickableRegions
                )
                CardDivider()
                SettingsToggle(
                    title: "Show messages",
                    help: "Messages pop up over the game instead of behind it.",
                    isOn: $settings.overlayShowsNotifications
                )
            }
            SettingsCard {
                // **A header row and a bare control, never a control row.** A
                // segmented control inside `SettingsControlRow` expands past the
                // card it is in and gets clipped by the window instead — which
                // is what every other pane in this window avoids by doing it
                // this way.
                CardHeaderRow(
                    title: "Messages appear",
                    help: "Which corner the toasts stack in."
                )
                SettingsSegmentedControl(
                    selection: $settings.overlayNotificationCorner,
                    options: OverlayCorner.allCases.map {
                        .init($0, $0.title, symbolName: $0.symbolName)
                    }
                )
            }
            .disabled(!settings.overlayShowsNotifications)
        }

        SettingsGroup("Voice widget") {
            SettingsCard {
                CardHeaderRow(
                    title: "Show names",
                    help: "A name beside each face."
                )
                SettingsSegmentedControl(
                    selection: $settings.overlayVoiceNames,
                    options: OverlayNameDisplay.allCases.map {
                        .init($0, $0.title, symbolName: $0.symbolName)
                    }
                )
                CardDivider()
                CardHeaderRow(title: "Face size", help: "How big those faces are.")
                SettingsSegmentedControl(
                    selection: $settings.overlayAvatarSize,
                    options: OverlayAvatarSize.allCases.map {
                        .init($0, $0.title, symbolName: $0.symbolName)
                    }
                )
                CardDivider()
                SettingsSliderRow(
                    title: "Most people shown",
                    value: Binding(
                        get: { Double(settings.overlayVoiceLimit) },
                        set: { settings.overlayVoiceLimit = Int($0.rounded()) }
                    ),
                    range: 1...20,
                    step: 1,
                    format: { String(Int($0)) }
                )
            }
            SettingsFootnote("Whoever\u{2019}s talking always comes first.", symbolName: "waveform")
        }

        SettingsGroup("Widgets") {
            SettingsCard {
                ForEach(Array(OverlayWidgetKind.allCases.enumerated()), id: \.element) {
                    index, kind in
                    if index > 0 { CardDivider() }
                    WidgetRow(kind: kind, controller: model.overlay)
                }
            }
            SettingsFootnote(
                "Pinned widgets stay up while you play; the rest wait for the overlay. "
                    + "Arrange them from the overlay itself.",
                symbolName: "pin"
            )
            // **The way back, and it has to be here rather than on the
            // overlay.** A layout somebody has made a mess of is hardest to fix
            // from inside the thing they made a mess of — Default is the reset.
            OverlayLayoutCard(controller: model.overlay)
            if StreamerMode.shared.isEnabled, !StreamerMode.shared.hiddenOverlayWidgets.isEmpty {
                SettingsCard {
                    SettingsNavigationRow(
                        title: "Go to Streamer Mode Settings",
                        subtitle: "Some overlay features are restricted by Streamer Mode.",
                        symbolName: SettingsSection.streamerMode.symbolName,
                        tint: SettingsSection.streamerMode.tint
                    ) { navigate(.streamerMode) }
                }
            }
        }
    }

    private var keySummary: String {
        let open = settings.hotkey(for: .toggleOverlay)?.displayString ?? "unbound"
        let lock = settings.hotkey(for: .toggleOverlayLock)?.displayString ?? "unbound"
        return "Open \(open) · Hand back the mouse \(lock)"
    }
}

private struct WidgetRow: View {
    var kind: OverlayWidgetKind
    @Bindable var controller: OverlayController

    var body: some View {
        SettingsControlRow(kind.title, help: help) {
            HStack(spacing: Spacing.snug) {
                // **Absent rather than disabled where pinning is refused** — see
                // `OverlayWidgetKind.canBePinned`. A greyed pin is a control
                // describing a state nobody can reach, which reads as a feature
                // that is missing rather than one that does not apply.
                if kind.canBePinned { pinButton }
                Toggle(
                    "",
                    isOn: Binding(
                        get: { controller.layout.placement(for: kind).isEnabled },
                        set: { enabled in
                            var layout = controller.layout
                            layout.setEnabled(enabled, for: kind)
                            controller.layout = layout
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(kind.title)
            }
        }
    }

    private var pinButton: some View {
        Button {
            var layout = controller.layout
            layout.setPinned(!isPinned, for: kind)
            controller.layout = layout
        } label: {
            Image(symbol: isPinned ? "pin.fill" : "pin.slash")
                .font(.system(size: 12))
                // Secondary rather than tertiary when unpinned: measured
                // against the card it sat on, tertiary was too close to the
                // ground to read as a control at all.
                .foregroundStyle(
                    isPinned ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary)
                )
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Shown while you play" : "Only when the overlay is open")
        .accessibilityLabel(isPinned ? "Unpin \(kind.title)" : "Pin \(kind.title)")
    }

    private var isPinned: Bool { controller.layout.placement(for: kind).isPinned }

    private var help: String? {
        if StreamerMode.shared.hiddenOverlayWidgets.contains(kind) { return "Hidden while Streamer Mode is on." }
        switch kind {
        case .activity: return "What you\u{2019}re showing as your activity, with its switches."
        case .performance: return "Processor, graphics, memory and heat, once a second."
        default: return nil
        }
    }
}

/// The arrangement: Discord's, three more built in, and the reader's own.
///
/// **Menu items with checkmarks, not a picker.** The current layout may be
/// none of them — it is whatever the reader dragged — and a picker would have
/// to pretend otherwise.
private struct OverlayLayoutCard: View {
    @Bindable var controller: OverlayController
    @State private var renaming: OverlaySavedLayout?
    @State private var name = ""

    var body: some View {
        SettingsCard {
            SettingsControlRow("Layout", help: help) {
                Menu(title) {
                    Section("Presets") {
                        ForEach(OverlayLayoutPreset.allCases) { preset in
                            Toggle(isOn: Binding(
                                get: { controller.currentPreset == preset },
                                set: { _ in controller.apply(preset) }
                            )) {
                                Label(preset.title, systemImage: preset.symbolName)
                            }
                        }
                    }
                    if !controller.savedLayouts.isEmpty {
                        Section("Your layouts") {
                            ForEach(controller.savedLayouts) { saved in
                                Toggle(saved.name, isOn: Binding(
                                    get: { controller.currentSavedLayout?.id == saved.id },
                                    set: { _ in controller.apply(saved) }
                                ))
                            }
                        }
                    }
                    Divider()
                    Button("Save Current Layout") { controller.saveCurrentLayout() }
                        .disabled(!canSave)
                }
                .fixedSize()
                .controlSize(.small)
            }
            ForEach(controller.savedLayouts) { saved in
                CardDivider()
                SettingsControlRow(saved.name, help: "Saved") {
                    HStack(spacing: Spacing.tight) {
                        Button("Rename…") {
                            name = saved.name
                            renaming = saved
                        }
                        Button("Delete", role: .destructive) { controller.deleteSavedLayout(saved.id) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .modal(
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            style: .alert
        ) {
            if let saved = renaming {
                ModalAlert(
                    hero: .symbol("rectangle.3.group"),
                    title: "Rename Layout",
                    actions: [
                        .cancel(),
                        .act("Rename", symbol: "pencil", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                            controller.renameSavedLayout(saved.id, to: name)
                        },
                    ]
                ) {
                    ModalTextField(placeholder: "Name", text: $name, symbolName: "pencil")
                }
            }
        }
    }

    private var title: String {
        controller.currentPreset?.title ?? controller.currentSavedLayout?.name ?? "Custom"
    }

    private var help: String {
        if let preset = controller.currentPreset { return preset.summary }
        if controller.currentSavedLayout != nil { return "One of your saved layouts." }
        return "Arranged by you. Save it to come back to it."
    }

    private var canSave: Bool {
        controller.currentSavedLayout == nil && controller.currentPreset == nil
            && controller.savedLayouts.count < OverlaySavedLayout.limit
    }
}

// MARK: - Clips

struct ClipsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsNavigate) private var navigate
    @State private var settings = AppSettings.shared
    @State private var clips: [Clip] = []
    /// The account's own setting, mirrored so the switch moves at once; the
    /// model writes it and puts it back if Discord refuses.
    @State private var allowsVoiceRecording = true

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Keep the last moments",
                help: "Wingcord holds on to the last moments of your game, so the clip key can "
                    + "save what just happened.",
                isOn: $settings.clipsEnabled
            )
        }
        SettingsFootnote(
            "Nothing is saved until you press the key, and only the game\u{2019}s window is kept "
                + "\u{2014} never your screen or your notifications.",
            symbolName: "lock.shield"
        )

        SettingsGroup("Length and quality") {
            SettingsCard {
                CardHeaderRow(
                    title: "Length",
                    help: "How much of what just happened a clip keeps."
                )
                SettingsSegmentedControl(
                    selection: $settings.clipLength,
                    options: ClipLength.allCases.map { .init($0, $0.title) }
                )
                CardDivider()
                CardHeaderRow(
                    title: "Resolution",
                    help: "The tallest a clip is recorded at. A bigger window is scaled down to it."
                )
                SettingsSegmentedControl(
                    selection: $settings.clipResolution,
                    options: ClipResolution.allCases.map { .init($0, $0.title) }
                )
                CardDivider()
                CardHeaderRow(title: "Frame rate", help: "The most frames a second a clip keeps.")
                SettingsSegmentedControl(
                    selection: $settings.clipFrameRate,
                    options: ClipFrameRate.allCases.map { .init($0, $0.title) }
                )
            }
            SettingsFootnote(memoryNote, symbolName: "memorychip")
        }

        SettingsGroup("Voice") {
            SettingsCard {
                SettingsToggle(
                    title: "Allow my voice to be recorded in Clips",
                    help: "Lets the people in your calls keep your voice in their clips. Saved to your "
                        + "account, so it holds in Discord too.",
                    isOn: $allowsVoiceRecording
                )
                if model.connectedVoiceChannelID != nil {
                    CardDivider()
                    SettingsValueRow(
                        title: "In this call",
                        value: callClippingValue,
                        help: "People here whose clips are on."
                    )
                }
            }
            SettingsFootnote(
                "Clips keep your mic, the soundboard and everyone who allows it, each on its own "
                    + "track. Stages are never recorded.",
                symbolName: "person.wave.2"
            )
        }
        .task { allowsVoiceRecording = model.syncedPreferences.allowsVoiceRecordingInClips }
        .onChange(of: model.syncedPreferences.allowsVoiceRecordingInClips) { _, allows in
            allowsVoiceRecording = allows
        }
        .onChange(of: allowsVoiceRecording) { _, allows in
            model.setAllowsVoiceRecordingInClips(allows)
        }

        // Discord's Auto Clips (Phase 7.2), in its words where it has them.
        SettingsGroup("Auto Clips") {
            SettingsCard {
                SettingsToggle(
                    title: "Enable Auto Clips",
                    help: "Automatically capture gaming moments with Auto Clips.",
                    isOn: Binding(
                        get: { settings.autoClipsEnabled },
                        set: { settings.autoClipsEnabled = $0; model.autoClips.refresh() }
                    )
                )
                CardDivider()
                SettingsToggle(
                    title: "Laughter and shouting",
                    help: "Listens to the call and your mic for a laugh or a shout.",
                    isOn: Binding(
                        get: { settings.autoClipsHearsReactions },
                        set: { settings.autoClipsHearsReactions = $0; model.autoClips.refresh() }
                    )
                )
                CardDivider()
                SettingsToggle(
                    title: "In-game events",
                    help: "Kills, multikills, aces and wins, from the games that report them.",
                    isOn: Binding(
                        get: { settings.autoClipsHearsGameEvents },
                        set: { settings.autoClipsHearsGameEvents = $0; model.autoClips.refresh() }
                    )
                )
            }
            .disabled(!settings.clipsEnabled)
            SettingsFootnote(
                settings.clipsEnabled
                    ? "Auto Clips wait in the library\u{2019}s To Review. The listening happens on "
                        + "this Mac, and only while a game is in front."
                    : "Turn on Keep the last moments first.",
                symbolName: "sparkles"
            )
        }

        SettingsGroup("Recording") {
            SettingsCard {
                SettingsActionRow(
                    "Library",
                    help: "Every clip, recording and screenshot — to watch, edit and share.",
                    actionTitle: "Open"
                ) { ClipsWindow.open() }
                CardDivider()
                SettingsActionRow(
                    "Capture bar",
                    help: "Record the screen, a window or an area — or take a picture of one. "
                        + captureKeySummary,
                    actionTitle: "Open"
                ) { model.capture.showBar() }
            }
            SettingsFootnote(
                "Screen, camera, mic and sound each get their own track, so the editor can mix "
                    + "them any way. Calls are never recorded.",
                symbolName: "record.circle"
            )
        }

        SettingsGroup("Where they go") {
            SettingsCard {
                SettingsActionRow(
                    "Folder",
                    help: ClipLibrary.folder.path(percentEncoded: false),
                    actionTitle: "Choose…"
                ) { chooseFolder() }
                CardDivider()
                SettingsActionRow(
                    "Open in Finder",
                    help: sizeSummary,
                    actionTitle: "Open"
                ) {
                    try? FileManager.default.createDirectory(
                        at: ClipLibrary.folder, withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(ClipLibrary.folder)
                }
            }
        }

        SettingsGroup("Recent") {
            SettingsCard {
                if clips.isEmpty {
                    SettingsValueRow(
                        title: "Nothing yet",
                        value: "—",
                        help: "Press \(clipKey) while a game is running."
                    )
                } else {
                    ForEach(Array(clips.prefix(8).enumerated()), id: \.element.id) { index, clip in
                        if index > 0 { CardDivider() }
                        ClipRow(clip: clip) { remove(clip) }
                    }
                }
            }
        }
        .task(id: model.clipsRevision) { clips = ClipLibrary.contents() }

        SettingsGroup("While you play") {
            SettingsCard {
                SettingsToggle(
                    title: "Say so on the overlay",
                    help: "A line over the game confirming the clip was written.",
                    isOn: $settings.clipsShowsFeedback
                )
            }
        }
    }

    /// What the chosen length and quality hold while a game is in front.
    private var memoryNote: String {
        let bytes = ClipRecorder.estimatedBytes()
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        let budget = ByteCountFormatter.string(fromByteCount: Int64(ClipRecorder.memoryBudget), countStyle: .memory)
        return bytes > ClipRecorder.memoryBudget
            ? "About \(size) while a game is in front. Past \(budget), the oldest seconds wait on "
                + "disk until the game closes."
            : "About \(size) of memory while a game is in front, and none otherwise."
    }

    private var callClippingValue: String {
        switch model.callMembersClipping {
        case 0: "Nobody"
        case 1: "1 person"
        case let count: "\(count) people"
        }
    }

    private var clipKey: String {
        settings.hotkey(for: .saveClip)?.displayString ?? "the clip key"
    }

    private var captureKeySummary: String {
        settings.hotkey(for: .showCaptureBar).map { "Or press \($0.displayString) anywhere." } ?? ""
    }

    private var sizeSummary: String {
        let bytes = clips.reduce(0) { $0 + $1.byteCount }
        guard bytes > 0 else { return "Nothing saved yet." }
        return "\(clips.count) files, \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    private func remove(_ clip: Clip) {
        try? ClipLibrary.delete(clip)
        model.clipsRevision &+= 1
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = ClipLibrary.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.clipsFolder = url
        model.clipsRevision &+= 1
    }
}

private struct ClipRow: View {
    var clip: Clip
    var remove: () -> Void

    var body: some View {
        SettingsControlRow(clip.name, help: caption) {
            HStack(spacing: Spacing.base) {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                Button("Delete", role: .destructive, action: remove)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
    }

    private var caption: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clip.byteCount), countStyle: .file)
        let kind = clip.isRecording ? "Recording" : clip.isScreenshot ? "Screenshot" : "Clip"
        var parts = [kind, size]
        if let take = clip.take {
            parts.append(Duration.seconds(take.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
            if take.hasCamera { parts.append("camera") }
        }
        // What the sidecar knows: how long, and whose voices are in it.
        if let manifest = clip.manifest {
            parts.append(Duration.seconds(manifest.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
            let voices = manifest.tracks.count { track in
                switch track.role {
                case .microphone, .voice: true
                case .mix, .game, .soundboard: false
                }
            }
            if voices > 0 { parts.append(voices == 1 ? "1 voice" : "\(voices) voices") }
        }
        parts.append(clip.created.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}
