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

    var body: some View {
        nowPlaying
        sharing
        whereShared
        joining
        registeredGames
    }

    // MARK: What is running

    @ViewBuilder private var nowPlaying: some View {
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
            } else {
                SettingsValueRow(
                    title: "Nothing detected",
                    value: "—",
                    help: "Start a game and it appears here. Wingcord watches which applications "
                        + "are running; it never reads what is in them."
                )
            }
        }
        if model.detectedGame == nil {
            SettingsFootnote(
                "Discord's detection list has sixty-two Mac games on it and eleven thousand "
                    + "Windows ones, so most titles are recognised through Whisky, CrossOver or "
                    + "Game Porting Toolkit rather than natively. Anything it does not know can "
                    + "be added by hand below.",
                symbolName: "gamecontroller"
            )
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
                    help: "Lets friends and servers see the game you are playing.",
                    isOn: Binding(
                        get: { privacy.sharesCurrentGame },
                        set: { model.setSharesCurrentGame($0) }
                    )
                )
            }
            SettingsFootnote(
                "This one follows your account rather than this Mac — it is the same switch "
                    + "Discord calls Share my activity, and turning it off here turns it off "
                    + "everywhere you are signed in.",
                symbolName: "icloud"
            )
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
                            Image(systemName: isSelected(scope)
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
                    ? "Your friends always see it. This is about servers — and \"small\" means "
                        + "two hundred members or fewer, which is Discord's own line."
                    : "These are ignored while Share my activity is off.",
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
                "Some games let people jump straight into your session from your activity. "
                    + "These decide whether they need to ask.",
                symbolName: "person.badge.plus"
            )
        }
    }

    // MARK: Registered games

    private var registeredGames: some View {
        SettingsGroup("Games added by hand") {
            SettingsCard {
                if settings.manualGames.isEmpty {
                    SettingsValueRow(
                        title: "None yet",
                        value: "—",
                        help: "Add anything Wingcord does not recognise — including an "
                            + "application that is not a game."
                    )
                } else {
                    ForEach(Array(settings.manualGames.enumerated()), id: \.element.path) {
                        index, entry in
                        if index > 0 { CardDivider() }
                        SettingsActionRow(
                            entry.name,
                            help: entry.path,
                            actionTitle: "Remove",
                            role: .destructive
                        ) {
                            settings.removeManualGame(at: entry.path)
                            model.sessionController.games.removeManualGame(forExecutableAt: entry.path)
                        }
                    }
                }
            }
            AddGameRow()
        }
    }
}

/// The "Add it!" picker — everything running, by process.
///
/// **Running processes, not an app chooser.** Discord's own picker lists
/// `getCandidateGames()`, which is the set of running processes keyed by pid,
/// and that is what makes it possible to add the thing you are looking at
/// rather than hunting for its bundle in `/Applications`.
private struct AddGameRow: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    @State private var isPicking = false

    var body: some View {
        SettingsCard {
            SettingsControlRow(
                "Add a game",
                help: "Everything currently running that has a window."
            ) {
                Button("Choose…") { isPicking = true }
                    .buttonStyle(.glass)
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
            rawValue: UInt64(bitPattern: Int64(abs(candidate.executableURL.path.hashValue)))
        )
        settings.addManualGame(name: candidate.name, path: candidate.executableURL.path, id: id)
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
                help: "Wingcord draws over whatever you are playing. Nothing is injected into "
                    + "the game — it is a window floating above it.",
                isOn: $settings.isOverlayEnabled
            )
        }
        SettingsFootnote(
            "It works over a game running windowed or borderless-fullscreen, which on a Mac is "
                + "very nearly all of them. A game that takes the display outright will cover it.",
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
                "Escape closes the overlay, clicking the dimmed background closes it, and "
                    + "holding ⌥ hides every widget for as long as you hold it.",
                symbolName: "escape"
            )
        }

        SettingsGroup("While you are playing") {
            SettingsCard {
                SettingsToggle(
                    title: "Let pinned widgets be clicked",
                    help: "Pinned widgets take clicks even while the overlay is asleep. Handy "
                        + "for muting; awkward if your crosshair is over one. A message toast "
                        + "answers a click either way.",
                    isOn: $settings.overlayHasClickableRegions
                )
                CardDivider()
                SettingsToggle(
                    title: "Show messages",
                    help: "Messages appear over the game instead of in Notification Center, "
                        + "which is behind it.",
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
                    help: "Whether a name is drawn beside each face."
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
            SettingsFootnote(
                "Whoever is talking is always shown first, so the cap never hides the person "
                    + "making noise.",
                symbolName: "waveform"
            )
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
                "A pinned widget stays on screen while you are playing. Everything else appears "
                    + "only when you open the overlay. Drag them where you want them from the "
                    + "overlay's own arrange button.",
                symbolName: "pin"
            )
            // **The way back, and it has to be here rather than on the
            // overlay.** A layout somebody has made a mess of is hardest to fix
            // from inside the thing they made a mess of.
            SettingsCard {
                SettingsControlRow("Arrangement") {
                    Button("Reset") { model.overlay.resetLayout() }
                        .controlSize(.small)
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
        SettingsControlRow(kind.title) {
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
            Image(systemName: isPinned ? "pin.fill" : "pin.slash")
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
}

// MARK: - Clips

struct ClipsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsNavigate) private var navigate
    @State private var settings = AppSettings.shared
    @State private var clips: [Clip] = []

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Keep the last few seconds",
                help: "Wingcord buffers your game while you play, so the clip key can save what "
                    + "already happened.",
                isOn: $settings.clipsEnabled
            )
        }
        SettingsFootnote(
            "Nothing is written to disk until you press the key. The buffer runs only while a "
                + "game is in front, and it captures the game's own window — not your screen, "
                + "not this app, not your notifications.",
            symbolName: "lock.shield"
        )

        SettingsGroup("Quality") {
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
            SettingsFootnote(
                "Fifteen seconds is the ceiling, and it is macOS's rather than a choice: the "
                    + "system's rolling clip buffer stops there. Longer clips would mean "
                    + "Wingcord running its own encoder the whole time you play.",
                symbolName: "clock.arrow.circlepath"
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

    private var clipKey: String {
        settings.hotkey(for: .saveClip)?.displayString ?? "the clip key"
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
                    .controlSize(.small)
                Button("Delete", role: .destructive, action: remove)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    private var caption: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clip.byteCount), countStyle: .file)
        let kind = clip.isScreenshot ? "Screenshot" : "Clip"
        return "\(kind) · \(size) · \(clip.created.formatted(.relative(presentation: .named)))"
    }
}
