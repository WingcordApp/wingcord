import AppIntents
import AppKit
import SwiftUI
import WingcordNet
import WingcordVoice

@main
struct WingcordApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(WingcordAppDelegate.self) private var appDelegate

    init() {
        // Installed before anything else can crash. The report file is opened
        // while the process is healthy precisely so the signal handler never has
        // to allocate.
        CrashReporter.install()
        // **And taken down again on a clean exit.** The report file is created
        // at launch so the signal handler never has to allocate, which means a
        // normal quit leaves a header-only file behind — indistinguishable from
        // a crash on the next launch. `finishCleanly` removes it, and without
        // this call every ordinary quit reported a crash that never happened.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in CrashReporter.finishCleanly() }
        // **Memory the app is holding for a window nobody is looking at.**
        // `PerformanceMonitor` already knows how to shed the large decoded
        // images twenty seconds after the window goes away, and to cancel that
        // the moment it comes back — it was simply never told when either
        // happened, so the shed never ran and a hidden window cost as much as a
        // visible one.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidHide() } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidHide() } }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidShow() } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MemoryPressureWatcher.shared.windowDidShow() } }
        if DiagnosticLog.isEnabled {
            GatewaySocket.traceSink = { message in
                DiagnosticLog.trace("gateway", message)
            }
            DiscordREST.traceSink = { message in
                DiagnosticLog.trace("rest", message)
            }
            // **The voice handshake is four steps, DAVE's is nine more, and
            // every way either fails is silent**, so the whole stack gets a
            // sink. Without this a call that never comes up produces exactly
            // as much evidence as one that does: none.
            VoiceTrace.sink = { message in
                DiagnosticLog.trace("voice", message)
            }
        }
        DiagnosticLog.trace("app", "launched")
        // The theme, before anything can paint with it.
        //
        // `Palette` would build this store lazily on its first read anyway, but
        // the first read is not guaranteed to be on the main thread — a drawn
        // canvas laying out a fixture would reach `ThemeRuntime` instead and get
        // the house palette, and the window would come up in True Black for one
        // frame before correcting itself.
        _ = ThemeStore.shared
        VoiceNoteRecorder.clearLeftovers()
        let model = AppModel()
        if LaunchOptions.current.usesDemoFixtures {
            DemoFixtures.populate(model)
        }
        if LaunchOptions.current.pretendsAGameIsRunning {
            DemoFixtures.populateDetectedGame(model)
        }
        _model = State(initialValue: model)
        model.capture.model = model
        PerformanceMonitor.shared.model = model
        WingcordAppDelegate.model = model
        MemoryPressureWatcher.shared.model = model
        // **Here, before any intent can run.** The system launches the app for
        // a Shortcut or a Focus filter and runs this initialiser even when no
        // window ever opens — a view modifier would come too late, and the
        // intent would find nothing registered.
        let focusSync = FocusSync(model: model)
        model.focusSync = focusSync
        AppDependencyManager.shared.add(dependency: model)
        AppDependencyManager.shared.add(dependency: focusSync)
        focusSync.checkAtLaunch()
        // `--demo` has no session to start it: what plays is read and built
        // the same way, and shown on the reader's own card only.
        if LaunchOptions.current.usesDemoFixtures {
            model.sessionController.startNowPlayingLocally()
            DemoCaptureSelfTest.runIfAsked(model)
            // On the next turn, once there's a window to open it in.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                DemoVoiceNotes.openRequestedChannel(model)
            }
        }
    }

    var body: some Scene {
        // A single `Window`, not a `WindowGroup`. A group restores every
        // previously opened window on the next launch, and this app owns one
        // workspace — a second copy of it would hold a second gateway
        // connection's worth of state.
        Window("Wingcord", id: "main") {
            // ORDER MATTERS, and getting it wrong is a launch crash rather
            // than a subtle defect. `.environment` supplies a value to the view
            // it is applied to and its DESCENDANTS — so a modifier attached
            // after it wraps that view and sits OUTSIDE the scope, where the
            // value it needs does not exist. Every modifier that reads the store
            // therefore goes above `.environment`, which stays outermost.
            RootView()
                // Above every ground, and above nothing else: the two columns
                // read their own place in this space to draw one picture across
                // both of them. See `ThemeGround.swift`.
                .backdropSpace()
                .mirrorsUnreadCountOnDock()
                .wearsServerThemes()
                .installsGlobalHotkey()
                .providesSettingsWindow()
                .providesServerSettingsWindow()
                .providesClipsWindow()
                .showsPerformanceInspector()
                // **Before every layer a tile or a control can raise**, so a
                // profile or a flyout opened from the full-screen call comes up
                // over it.
                .presentsCallFullScreen()
                .presentsMedia()
                .presentsMessageActions()
                .presentsProfiles()
                // **After the profiles, so it draws over them.** A game profile
                // is opened from a tile inside the full profile and has to sit
                // on top of the surface that raised it.
                .presentsGameProfile()
                // **After the game profile**, for the same reason it comes
                // after the profiles: a tenure badge is clicked on a badge row
                // that can be inside either of them.
                .presentsTenureBadge()
                .presentsSpotifyPlayer()
                .presentsUserMenu()
                .presentsDirectMessageMenu()
                .presentsServerOptions()
                .presentsChannelOptions()
                .presentsThreadOptions()
                .presentsCrosspostCards()
                .presentsAutoModCards()
                .presentsConversationHeads()
                .presentsActivityInfo()
                .presentsExpressionInfo()
                .presentsInvokedCommand()
                .presentsGuildSurfaces()
                .presentsJoinServer()
                // **Every link a view opens with `openURL`** goes past the invite
                // sheet first, `Link` and markdown too, so none of them can skip
                // it for the browser.
                .environment(\.openURL, OpenURLAction { url in
                    model.openInviteLink(url.absoluteString) ? .handled : .systemAction
                })
                .presentsSearchFilters()
                .presentsVoiceSurfaces()
                // **Last, so it draws over every one of them.** ⌘K is reached
                // from anywhere — including from on top of a profile card or a
                // game page — and a switcher that opened underneath the surface
                // it was summoned from would be invisible.
                .presentsQuickSwitcher()
                // **After every presenter**, so a card is over whatever raised
                // it — a profile, the switcher, the events.
                .hostsModals(publish: { model.isModalShown = $0 })
                .watchesPushToTalk()
                .publishesGameActivity()
                // The menu bar's workspace commands are on while this window is
                // in front, and only then — `FocusedValues.workspaceIsKey`.
                .focusedSceneValue(\.workspaceIsKey, true)
                .resolvesMotion()
                .environment(model)
                .frame(
                    minWidth: Proportions.windowMinWidth,
                    minHeight: Proportions.windowMinHeight
                )
        }
        .defaultSize(width: 1180, height: 760)
        // **No title bar and no toolbar** — the shell draws its own header rows
        // level with the traffic lights (REDESIGN.md R2). Measured 2026-10-13:
        // in a hidden-title-bar window with no toolbar, a control drawn in that
        // band takes clicks; with a toolbar it did not (INVARIANTS §1).
        .windowStyle(.hiddenTitleBar)
        .commands { WingcordCommands(model: model) }

        // An ordinary `Window`, not a `Settings` scene — see `SettingsWindow`
        // for why. It wears the settings scene's shortcut and menu item, which
        // `WingcordCommands` installs.
        Window("Settings", id: SettingsWindow.sceneID) {
            SettingsView()
                .hostsModals()
                .resolvesMotion()
                .environment(model)
        }
        .defaultSize(
            width: SettingsMetrics.defaultWidth,
            height: SettingsMetrics.defaultHeight
        )
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        // The scene inherits no File menu of its own; the app has one workspace
        // and one settings window, and neither is a document.
        .commandsRemoved()

        // The clips library — Discord's Clips Home, a window of its own
        // (docs/CLIPS-PRESENCE.md, Phase 4.2).
        Window("Clips", id: ClipsWindow.sceneID) {
            ClipsLibraryView()
                .hostsModals()
                .resolvesMotion()
                .environment(model)
        }
        .defaultSize(width: 1_100, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        // A server's own settings.
        //
        // **A `WindowGroup` here, where the two above are single `Window`s**,
        // and the difference is the point: this scene is *about* something. Two
        // servers' settings can be open at once — comparing two permission sets
        // is the most ordinary reason to want that — so the scene takes a value
        // and macOS keys a window per server off it.
        WindowGroup(id: ServerSettingsWindow.sceneID, for: ServerSettingsTarget.self) { target in
            if let value = target.wrappedValue {
                ServerSettingsView(target: value, model: model, controller: model.sessionController)
                    .hostsModals()
                    .resolvesMotion()
                    .environment(model)
            }
        }
        .defaultSize(
            width: SettingsMetrics.defaultWidth,
            height: SettingsMetrics.defaultHeight
        )
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}

struct WingcordCommands: Commands {
    /// The store, so the navigation items can act and can say when they cannot.
    ///
    /// Commands are built once per scene rather than per frame, and every item
    /// below reads a memoized projection — so an always-present menu costs a
    /// bounds check when it is opened and nothing at all when it is not.
    var model: AppModel

    /// Whether the workspace is in front — see `FocusedValues.workspaceIsKey`.
    /// Read once per build of the menu bar, and it moves only when the key
    /// window does, so it costs §4.95 nothing.
    @FocusedValue(\.workspaceIsKey) private var workspaceIsKey

    var body: some Commands {
        let isWorkspace = workspaceIsKey == true
        // The New Window and New Document items a default menu bar carries
        // point at scenes this app does not have; Discord's ⇧⌘N, Create or
        // join a server, stands where they were.
        CommandGroup(replacing: .newItem) {
            // Messages' ⌘N, and the friends it writes to (REDESIGN.md R12).
            Button("New Message…") { NewMessageRequest.shared.isShown = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!isWorkspace)
            Button("Add Friend…") { AddFriendRequest.shared.isShown = true }
                .disabled(!isWorkspace)
            ShortcutMenuItem(shortcut: .addServer, model: model)
                .disabled(!isWorkspace)
            Divider()
            // The capture bar's way in, beside its global key.
            if model.capture.isRecording {
                Button("Stop Recording") { Task { await model.capture.stopRecording() } }
            } else {
                Button("Record or Capture the Screen…") { model.capture.showBar() }
            }
            Button("Save Clip") { model.saveClip() }
                .disabled(!AppSettings.shared.clipsEnabled)
            Button("Clips Library") { ClipsWindow.open() }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
        // Settings is a `Window` scene rather than a `Settings` scene, so the
        // item and its ⌘, are installed by hand. Same title and same shortcut
        // macOS would have given it, in the same place in the app menu.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindow.open() }
                .keyboardShortcut(",", modifiers: .command)
            // Discord's Streamer Mode, where an app-wide state belongs: the
            // app menu, checked while it is on. Its global key is in
            // Shortcuts.
            Toggle("Streamer Mode", isOn: Binding(
                get: { StreamerMode.shared.isEnabled },
                set: { StreamerMode.shared.setEnabled($0) }
            ))
        }

        // **The menu bar is Alex's reference** (DESIGN-NOTES §10, images
        // 33–43): Edit, View, User, Channel, Voice, Window — Channel before
        // Voice, as its note asks. The HIG's rule is that every toolbar item is
        // also a command here; the ones whose acts do not exist yet are listed
        // in §10.1 rather than shown greyed for ever.
        //
        // **Every rebindable equivalent is read from `AppSettings`**, through
        // `ShortcutMenuItem`: one table — `AppShortcut` — carries the title,
        // the default, the availability test and the verb, so a row in the
        // Shortcuts pane and an item here cannot come to mean different things.

        // View › Show/Hide Sidebar, ⌃⌘S — the reference's "Expand Side Bar" —
        // and the sidebar's style. The shell's own toggle, not the split view's:
        // there is no split view any more.
        CommandGroup(replacing: .sidebar) {
            Button(AppSettings.shared.isSidebarShown ? "Hide Sidebar" : "Show Sidebar") {
                ShellActions.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(!isWorkspace)
            Picker("Sidebar Style", selection: Binding(
                get: { AppSettings.shared.sidebarStyle },
                set: { ShellActions.setSidebarStyle($0) }
            )) {
                ForEach(SidebarStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .disabled(!isWorkspace)
            Divider()
            // The pages a two-finger swipe moves between — REDESIGN.md R8.
            // ⌃⌘ rather than ⌥⌘: ⌥⌘→ is Discord's own Direct Messages key.
            Button("Previous Sidebar Page") { SidebarPager.shared.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                .disabled(!isWorkspace)
            Button("Next Sidebar Page") { SidebarPager.shared.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                .disabled(!isWorkspace)
            // The rack, expanded — the rail's own button, as a command.
            Button(SidebarPager.shared.isRackExpanded ? "Hide All Servers" : "Show All Servers") {
                SidebarPager.shared.toggleAllServers()
            }
            .keyboardShortcut(.downArrow, modifiers: [.control, .command])
            .disabled(!isWorkspace)
            Picker("Sidebar Pages", selection: Binding(
                get: { AppSettings.shared.sidebarPages },
                set: { AppSettings.shared.sidebarPages = $0 }
            )) {
                ForEach(SidebarPageLayout.allCases) { layout in
                    Text(layout.label).tag(layout)
                }
            }
            .disabled(!isWorkspace)
        }

        CommandGroup(after: .pasteboard) {
            Group {
                Divider()
                Menu("Search") {
                    ShortcutMenuItem(shortcut: .searchChannel, model: model)
                    Divider()
                    ShortcutMenuItem(shortcut: .quickSwitcher, model: model, title: "Quick Search")
                }
                Divider()
                // Return's own act — ⌘↩ is Discord's Answer Call.
                Button("Send Message") { ComposerFormatCommand.send(.send) }
                    .disabled(!model.menuContext.isConversation)
                ShortcutMenuItem(shortcut: .replyToLastMessage, model: model)
                ShortcutMenuItem(shortcut: .forwardLastMessage, model: model)
                // A fixed title: reading whether the newest message is pinned
                // would re-read the message list on every message — `MenuContext`.
                Button("Pin Last Message") { model.togglePinOnLatestMessage() }
                    .disabled(!model.menuContext.isConversation)
                // Up in an empty composer, Discord's own key — not a menu key.
                Button("Edit Last Message") {
                    guard let channelID = model.selectedChannelID else { return }
                    model.editLatestOwnMessage(in: channelID)
                }
                .disabled(!model.menuContext.isConversation)
                Button("Delete Last Message…") { model.deleteLatestOwnMessage() }
                    .disabled(!model.menuContext.isConversation)
            }
            .disabled(!isWorkspace)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Make Text Bigger") { AppSettings.shared.textScale += 0.1 }
                .keyboardShortcut("+", modifiers: .command)
            // Discord's ⌘0, its zoom reset.
            Button("Make Text Normal Size") { AppSettings.shared.textScale = 1 }
                .keyboardShortcut("0", modifiers: .command)
            Button("Make Text Smaller") { AppSettings.shared.textScale -= 0.1 }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Group {
                ShortcutMenuItem(shortcut: .showPins, model: model)
                ShortcutMenuItem(shortcut: .showThreads, model: model)
                ShortcutMenuItem(shortcut: .memberList, model: model)
                ShortcutMenuItem(shortcut: .inbox, model: model)
                Divider()
                ShortcutMenuItem(shortcut: .toggleCategories, model: model)
            }
            .disabled(!isWorkspace)
            Divider()
            // Alex's reference: the times on the messages, back under the
            // pointer.
            Toggle("Hide Times", isOn: Binding(
                get: { AppSettings.shared.hidesMessageTimes },
                set: { AppSettings.shared.hidesMessageTimes = $0 }
            ))
        }

        CommandMenu("User") {
            UserStatusPicker(model: model)
            // The custom-status editor lives on the reader's own card.
            Button("Set Status…") { model.openOwnCard(on: .customStatus) }
                .disabled(model.currentUserID == nil || !isWorkspace)
            Divider()
            Button("View Profile") {
                guard let userID = model.currentUserID else { return }
                model.openProfile(userID, anchor: .zero, depth: .full)
            }
            .disabled(model.currentUserID == nil || !isWorkspace)
            Button("Edit Profile…") { model.editOwnProfile() }
                .disabled(model.currentUserID == nil || !isWorkspace)
            Button("Edit Server Profile…") {
                guard let guildID = model.menuContext.guildID else { return }
                model.editPerServerProfile(in: guildID)
            }
            .disabled(model.menuContext.guildID == nil || !isWorkspace)
            Divider()
            // Vencord's CustomRPC toolbox item: the Rich Presence builder's
            // card last on, or the first (DESIGN-NOTES §11).
            Toggle("Show Custom RPC", isOn: Binding(
                get: { model.showsCustomPresence },
                set: { _ in model.toggleShowsCustomPresence() }
            ))
            .disabled(AppSettings.shared.customPresences.isEmpty)
            // Vencord's `/silenttype`. Wingcord has no built-in commands, so
            // the plugin's switch lives here, beside its other toolbox item
            // (decision 19) — dimmed while the plugin is off.
            Toggle("Enable Silent Typing", isOn: Binding(
                get: { AppSettings.shared.silentTypingIsOn },
                set: { AppSettings.shared.silentTypingIsOn = $0 }
            ))
            .disabled(!AppSettings.shared.silentTyping)
        }

        CommandMenu("Channel") {
            Group {
                ChannelRecentsMenu(model: model)
                Divider()
                ShortcutMenuItem(shortcut: .channelTopic, model: model, title: "Show Details")
                ShortcutMenuItem(shortcut: .voiceChat, model: model)
                Divider()
                ShortcutMenuItem(shortcut: .uploadFile, model: model)
                Button("Create a Poll") {
                    guard let channelID = model.menuContext.channelID else { return }
                    model.openPollEditor(in: channelID)
                }
                .disabled(!model.menuContext.isConversation)
                // D4: no key of its own by default. The composer's the place for this,
                // and an accidental shortcut here opens somebody's microphone.
                Button("Record Voice Message") {
                    guard let channelID = model.menuContext.channelID else { return }
                    model.startVoiceNote(in: channelID)
                }
                .disabled(!model.canRecordVoiceNote(in: model.menuContext.channelID))
                ShortcutMenuItem(shortcut: .viewGIFs, model: model)
                ShortcutMenuItem(shortcut: .viewEmojis, model: model)
                ShortcutMenuItem(shortcut: .viewStickers, model: model)
                ShortcutMenuItem(
                    shortcut: .createThread,
                    model: model,
                    title: model.menuContext.forum == nil ? nil : "New Post…"
                )
                ChannelForumMenu(model: model)
                Divider()
                ChannelProfileMenu(model: model)
                Divider()
                ShortcutMenuItem(shortcut: .startCall, model: model)
                Button("Start Video Call") {
                    guard let channelID = model.menuContext.channelID else { return }
                    model.startVideoCall(in: channelID)
                }
                .disabled(!AppShortcut.startCall.isAvailable(in: model))
                Divider()
                Button(model.menuContext.channelID.map { model.pinnedChannelIDs.contains($0) } == true ? "Unpin" : "Pin") {
                    guard let channelID = model.menuContext.channelID else { return }
                    model.setDirectMessagePinned(!model.pinnedChannelIDs.contains(channelID), channelID: channelID)
                }
                .disabled(!model.menuContext.isPrivate)
                Button("Close DM") {
                    guard let channelID = model.menuContext.channelID else { return }
                    model.closeDirectMessage(channelID)
                }
                .disabled(!model.menuContext.isPrivate)
                Divider()
                ChannelInviteMenu(model: model)
                // Discord's Add Friends to DM, which grows a group.
                Button("Add to Group DM…") {
                    guard let channelID = model.menuContext.channelID else { return }
                    model.groupInvite = channelID
                }
                .disabled(model.menuContext.kind != .groupDirectMessage)
                Divider()
                ChannelDeveloperMenu(model: model)
                ChannelSettingsMenu(model: model)
                Divider()
                ChannelNotificationsMenu(model: model)
                Divider()
                // Escape in the composer, Discord's own key — not a menu key.
                Button("Mark Channel Read") {
                    guard let channelID = model.selectedChannelID else { return }
                    model.markRead(channelID)
                }
                .disabled(model.menuContext.channelID == nil)
                ShortcutMenuItem(shortcut: .markServerRead, model: model)
                ShortcutMenuItem(shortcut: .markTopInboxChannelRead, model: model)
                ShortcutMenuItem(shortcut: .jumpToOldestUnread, model: model)
            }
            .disabled(!isWorkspace)
        }

        CommandMenu("Voice") {
            Button("Leave Voice Channel") { model.leaveVoice() }
                .disabled(model.connectedVoiceChannelID == nil)
            Button("Rejoin Last Voice Channel") { model.rejoinLastVoiceChannel() }
                .disabled(model.connectedVoiceChannelID != nil || model.lastVoiceChannelID == nil)
            ShortcutMenuItem(shortcut: .currentCall, model: model)
            ShortcutMenuItem(shortcut: .answerCall, model: model)
            Divider()
            Toggle(isOn: Binding(get: { model.isSelfMuted }, set: { _ in model.toggleVoiceMute() })) {
                Text(AppShortcut.toggleMute.menuTitle)
            }
            .keyboardShortcut(AppSettings.shared.shortcut(for: .toggleMute)?.keyboardShortcut)
            .disabled(!AppShortcut.toggleMute.isAvailable(in: model))
            Toggle(isOn: Binding(get: { model.isSelfDeafened }, set: { _ in model.toggleVoiceDeafen() })) {
                Text(AppShortcut.toggleDeafen.menuTitle)
            }
            .keyboardShortcut(AppSettings.shared.shortcut(for: .toggleDeafen)?.keyboardShortcut)
            .disabled(!AppShortcut.toggleDeafen.isAvailable(in: model))
            Toggle(isOn: Binding(get: { model.isCameraOn }, set: { _ in model.toggleCamera() })) {
                Text(AppShortcut.toggleCamera.menuTitle)
            }
            .keyboardShortcut(AppSettings.shared.shortcut(for: .toggleCamera)?.keyboardShortcut)
            .disabled(!AppShortcut.toggleCamera.isAvailable(in: model))
            Toggle("Share Screen", isOn: Binding(get: { model.isScreenSharing }, set: { _ in model.toggleScreenShare() }))
                .disabled(model.connectedVoiceChannelID == nil)
            Divider()
            Section("Camera") { VoiceDevicePicker(kind: .camera, model: model).labelsHidden() }
            Section("Microphone") {
                VoiceDevicePicker(kind: .input, model: model).labelsHidden()
                InputProfilePicker(model: model)
            }
            Section("Output") { VoiceDevicePicker(kind: .output, model: model).labelsHidden() }
        }

        // **Format, to Alex's reference** — on the composer being typed in, sent
        // down the responder chain (`ComposerFormatCommand`); with no composer
        // focused the item does nothing, as a Format menu does over a window
        // with no text in it. Only Bold carries its key here: the composer
        // takes ⌘I and ⌘U itself, which outside it are Inbox and Member List.
        CommandMenu("Format") {
            Group {
                Button("Bold") { ComposerFormatCommand.send(.format(.bold)) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { ComposerFormatCommand.send(.format(.italics)) }
                Button("Underline") { ComposerFormatCommand.send(.format(.underline)) }
                Button("Strikethrough") { ComposerFormatCommand.send(.format(.strikethrough)) }
                Divider()
                Button("Spoiler") { ComposerFormatCommand.send(.format(.spoiler)) }
                Menu("Codeblock") {
                    Button("Inline") { ComposerFormatCommand.send(.format(.inlineCode)) }
                    Button("Multiline") { ComposerFormatCommand.send(.codeBlock) }
                }
                Menu("Header") {
                    Button("Title") { ComposerFormatCommand.send(.linePrefix("# ")) }
                    Button("Heading") { ComposerFormatCommand.send(.linePrefix("## ")) }
                    Button("Subheading") { ComposerFormatCommand.send(.linePrefix("### ")) }
                }
                Button("Subtext") { ComposerFormatCommand.send(.linePrefix("-# ")) }
                Button("Quote") { ComposerFormatCommand.send(.quote) }
                Divider()
                Button("Add @mention") { ComposerFormatCommand.send(.insert("@")) }
                Button("Add @time") { ComposerFormatCommand.send(.insert("@time")) }
            }
            .disabled(!isWorkspace || !model.menuContext.isConversation)
        }

        // Window › going somewhere, above the window list — where the
        // reference puts Go to Next and Previous Channel. The servers follow.
        CommandGroup(before: .windowList) {
            Group {
                ShortcutMenuItem(shortcut: .nextChannel, model: model, title: "Go to Next Channel")
                ShortcutMenuItem(shortcut: .previousChannel, model: model, title: "Go to Previous Channel")
                ShortcutMenuItem(shortcut: .nextUnreadChannel, model: model, title: "Go to Next Unread Channel")
                ShortcutMenuItem(shortcut: .previousUnreadChannel, model: model, title: "Go to Previous Unread Channel")
                ShortcutMenuItem(shortcut: .nextMentionChannel, model: model, title: "Go to Next Unread Channel with Mentions")
                ShortcutMenuItem(shortcut: .previousMentionChannel, model: model, title: "Go to Previous Unread Channel with Mentions")
                Divider()
                ShortcutMenuItem(shortcut: .nextServer, model: model, title: "Go to Next Server")
                ShortcutMenuItem(shortcut: .previousServer, model: model, title: "Go to Previous Server")
                ShortcutMenuItem(shortcut: .directMessages, model: model)

                // Nine items rather than a loop over the servers the reader
                // happens to have: ⌘4 must mean the fourth server whether or not
                // there is one, or the shortcut changes meaning as you join and
                // leave. **Deliberately not rebindable** — nine rows in a
                // settings pane for one idea, and the idea is the digit.
                Menu("Servers") {
                    ForEach(1...9, id: \.self) { ordinal in
                        Button("Server \(ordinal)") { model.selectGuild(atOrdinal: ordinal) }
                            .keyboardShortcut(
                                KeyEquivalent(Character("\(ordinal)")), modifiers: .command
                            )
                    }
                }
                .disabled(!model.menuContext.isReady)
                Divider()
            }
            .disabled(!isWorkspace)
        }
    }
}

/// Launch arguments, read once.
///
/// Flags rather than a build configuration, so a release build can be driven
/// into a deterministic state for a screenshot or a benchmark without shipping
/// a second code path.
nonisolated struct LaunchOptions: Sendable {
    var usesDemoFixtures = false
    /// Pretends a game is in front, so the overlay comes up without one.
    ///
    /// **The overlay could not be looked at at all before this.** Every widget
    /// on it is gated on `detectedGame != nil`, and there is no fixture for a
    /// running process — so the one surface in this app that is only ever drawn
    /// over somebody else's window had no way to be drawn over anything. It is
    /// its own flag rather than part of `--demo` because it takes the screen:
    /// the panel presents at shield level and covers the menu bar, which is
    /// right over a game and wrong over a desktop somebody is working on.
    var pretendsAGameIsRunning = false
    /// A made-up voice in place of the microphone, so a voice message can be recorded
    /// with nobody talking and no system prompt: `--synthetic-microphone`. The demo
    /// falls back to this by itself where the microphone's refused.
    var usesSyntheticMicrophone = false
    /// Reduce Motion for this one run, so its paths can be looked at without flipping the
    /// system's setting under everything else on the Mac: `--reduce-motion`.
    var forcesReducedMotion = false

    static let current: LaunchOptions = {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        return LaunchOptions(
            // **The demo bundle is always the demo.** Opened from the Dock or
            // Finder it gets no arguments, and it used to sign in to the
            // reader's real account with the token in the Keychain — so a
            // profile edit "in the demo" was a real one (2026-10-22). Its own
            // identifier is the switch now, whatever it was launched with.
            usesDemoFixtures: arguments.contains("--demo")
                || Bundle.main.bundleIdentifier == "dev.wingcord.Wingcord.demo",
            pretendsAGameIsRunning: arguments.contains("--overlay"),
            usesSyntheticMicrophone: arguments.contains("--synthetic-microphone"),
            forcesReducedMotion: arguments.contains("--reduce-motion")
        )
    }()
}
