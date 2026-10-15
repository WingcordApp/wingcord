import SwiftUI
import WingcordCore

/// The window: one ground under everything, the sidebar panel over it, and the
/// detail column beside the panel. Replaces `NavigationSplitView` — see
/// `ShellMetrics` for why.
///
/// Three rules this view exists to keep:
///
///  1. **One ground.** The theme (or the reader's picture) is drawn once, under
///     the whole window, so the sidebar's glass and the conversation sit on the
///     same picture and no column can come out black (the per-column backdrop's
///     fault). Nothing else in the window paints an opaque ground of its own.
///  2. **The sidebar slides; the detail changes width once.** The panel moves
///     on an offset, which re-lays out nothing. The detail's leading inset moves
///     with the same spring, but the transcript inside it is exempt from the
///     animation and cross-fades its one re-layout instead (`ShellTransition`).
///  3. **The chrome is ours, and every control in it is also a menu command**
///     (the HIG's toolbar rule, kept now there is no toolbar).
struct WindowShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var settings = AppSettings.shared

    var body: some View {
        let layout = ShellLayout(
            style: settings.sidebarStyle,
            sidebarWidth: settings.sidebarWidth,
            isSidebarShown: settings.isSidebarShown,
            isTakenOver: model.isColumnTakenOver
        )
        ZStack(alignment: .topLeading) {
            DetailColumn(layout: layout)
                .padding(.leading, layout.detailLeading)

            SidebarPanel(layout: layout)
        }
        // The animated part of a change of state, keyed on the state and never
        // on the width: a drag on the panel's edge must track the pointer 1:1.
        .animation(motion.reposition, value: ShellMotionKey(layout))
        .ignoresSafeArea()
        // The ground is the shell's BACKGROUND, so nothing it draws can size
        // the window's content.
        .background {
            WallpaperLayer()
                .ignoresSafeArea()
        }
        .background {
            TrafficLightsPlacement(
                leading: ShellMetrics.trafficLightsLeading(layout.style),
                centerY: ShellMetrics.trafficLightsCenterY
            )
            .frame(width: 0, height: 0)
        }
        .capsWindowMinimumSize()
        // The wallpaper follows the conversation on screen — a conversation
        // can wear its own (REDESIGN.md R5).
        .onChange(of: model.selectedChannelID, initial: true) { _, channelID in
            WallpaperStore.shared.openConversation = channelID
        }
        .sheet(item: Binding(
            get: { WallpaperStore.shared.editing },
            set: { WallpaperStore.shared.editing = $0 }
        )) { request in
            ConversationBackgroundSheet(
                channelID: request.id,
                title: model.channelIndex[request.id].map { model.displayName(of: $0) } ?? "",
                close: { WallpaperStore.shared.editing = nil }
            )
        }
        // New Folder… and Rename Folder… for the conversation folders — asked
        // from menus, which cannot host a sheet of their own.
        .sheet(item: Binding(
            get: { DirectMessageFolders.shared.nameRequest },
            set: { DirectMessageFolders.shared.nameRequest = $0 }
        )) { request in
            FolderNameSheet(request: request)
        }
        .sheet(isPresented: Binding(
            get: { AddFriendRequest.shared.isShown },
            set: { AddFriendRequest.shared.isShown = $0 }
        )) {
            AddFriendSheet()
        }
        .sheet(isPresented: Binding(
            get: { NewMessageRequest.shared.isShown },
            set: { NewMessageRequest.shared.isShown = $0 }
        )) {
            NewMessageSheet()
        }
    }
}

/// Names a conversation folder: a new one, or one being renamed.
private struct FolderNameSheet: View {
    var request: DirectMessageFolders.NameRequest

    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var isNew: Bool {
        if case .create = request.purpose { return true }
        return false
    }

    private var canCommit: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base * 1.5) {
            Text(isNew ? "New Folder" : "Rename Folder")
                .font(.headline)
            Text("Folders keep conversations together. They stay on this Mac.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { DirectMessageFolders.shared.nameRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            name = request.initialName
            isFocused = true
        }
    }

    private func commit() {
        guard canCommit else { return }
        DirectMessageFolders.shared.complete(request, name: name)
    }
}

/// What changes the shell's arrangement as one gesture. The width is
/// deliberately absent — see `WindowShell`.
private struct ShellMotionKey: Equatable {
    var style: SidebarStyle
    var isSidebarShown: Bool
    var isTakenOver: Bool

    init(_ layout: ShellLayout) {
        style = layout.style
        isSidebarShown = layout.isSidebarShown
        isTakenOver = layout.isTakenOver
    }
}

// MARK: - Acts

/// What the sidebar's toggle, ⌃⌘S and View › Hide Sidebar all do.
@MainActor
enum ShellActions {
    static func toggleSidebar() {
        setSidebarShown(!AppSettings.shared.isSidebarShown)
    }

    static func setSidebarShown(_ shown: Bool) {
        guard AppSettings.shared.isSidebarShown != shown else { return }
        // The transcript's one re-layout lands inside this window and is
        // cross-faded rather than cut.
        ShellTransition.begin()
        AppSettings.shared.isSidebarShown = shown
    }

    static func setSidebarStyle(_ style: SidebarStyle) {
        guard AppSettings.shared.sidebarStyle != style else { return }
        ShellTransition.begin()
        AppSettings.shared.sidebarStyle = style
    }
}

/// A short window of time in which a change of the detail column's width is the
/// shell rearranging itself, not a resize — so the transcript dissolves its one
/// re-layout instead of cutting to it.
///
/// **A deadline on the main actor, not a value threaded through SwiftUI.** The
/// transcript is a drawn canvas several containers down, and the question it
/// asks is narrow and momentary: did the width that just changed change
/// because the sidebar moved?
@MainActor
enum ShellTransition {
    private static var until: ContinuousClock.Instant?

    /// How long after a toggle a width change still counts as the toggle's.
    private static let window: Duration = .milliseconds(450)

    static func begin() {
        until = .now + window
    }

    static var isActive: Bool {
        guard let until else { return false }
        return ContinuousClock.now < until
    }
}

// MARK: - The sidebar panel

private struct SidebarPanel: View {
    var layout: ShellLayout

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = PanelShape(style: layout.style)
        SidebarColumnContent(isTakenOver: layout.isTakenOver)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PanelHeaderRow(layout: layout)
                    // The pages, named, under the header — REDESIGN.md R8.
                    if !layout.isTakenOver {
                        SidebarPageSwitcher(pageWidth: layout.panelWidth)
                            .padding(.horizontal, Spacing.base + Spacing.hair)
                            .padding(.top, Spacing.tight)
                            .padding(.bottom, Spacing.tight)
                    }
                }
            }
            // Its top is the panel's top edge: where the header row, and so a
            // page's title, begins.
            .coordinateSpace(SidebarPanelSpace.space)
            .environment(\.shellLayout, layout)
            .environment(\.sidebarHeaderBand, layout.sidebarHeaderHeight)
            .frame(width: layout.panelWidth)
            .frame(maxHeight: .infinity)
            // The header band moves the window wherever nothing on it can be
            // pressed: a background, so the name and the controls drawn over
            // it take their own clicks first.
            .background(alignment: .top) {
                Color.clear
                    .frame(height: layout.sidebarHeaderHeight)
                    .dragsWindow()
            }
            .background {
                PanelGround(shape: shape, style: layout.style)
            }
            .clipShape(shape)
            .overlay(alignment: .trailing) {
                if layout.style == .docked {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(width: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if !layout.isTakenOver {
                    SidebarResizeHandle()
                        .offset(x: ShellMetrics.resizeHandleWidth / 2)
                }
            }
            .shadow(
                color: .black.opacity(layout.style == .floating && colorScheme == .dark ? 0.32 : 0.12),
                radius: layout.style == .floating ? 18 : 0,
                y: layout.style == .floating ? 6 : 0
            )
            .padding(.top, layout.panelTopInset)
            .padding(.leading, layout.panelInset)
            .padding(.bottom, layout.panelInset)
            .offset(x: layout.isSidebarShown ? 0 : layout.hiddenOffset)
            // A panel out of sight takes nothing: no clicks, no keyboard focus,
            // no VoiceOver stop.
            .allowsHitTesting(layout.isSidebarShown)
            .accessibilityHidden(!layout.isSidebarShown)
    }
}

/// The panel's silhouette: concentric with the window's corners when it floats,
/// a plain column when it is docked.
private nonisolated struct PanelShape: Shape {
    var style: SidebarStyle

    func path(in rect: CGRect) -> Path {
        switch style {
        case .floating:
            Path(roundedRect: rect, cornerRadius: ShellMetrics.floatingPanelRadius, style: .continuous)
        case .docked:
            Path(rect)
        }
    }
}

/// The panel's material: Liquid Glass (the HIG's sidebar), with a veil under the
/// rows so a bright picture behind the window cannot wash their text out.
private struct PanelGround: View {
    var shape: PanelShape
    var style: SidebarStyle

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                // The system substitutes an opaque material for glass; the veil
                // must not then take that most of the way to black (§1).
                shape.fill(Palette.surface)
            } else {
                // **A real blur under the glass.** Liquid Glass on its own lenses
                // the picture behind a large panel but barely frosts it, so a busy
                // wallpaper read straight through the rows. The system's own
                // sidebar is thicker for the same reason — the HIG: "Larger
                // elements like sidebars are more opaque, for legibility." The
                // standard material does the frosting, the glass keeps the rim.
                shape.fill(.thinMaterial)
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: shape)
                shape.fill(PanelVeil.color)
            }
        }
        .allowsHitTesting(false)
    }
}

nonisolated enum PanelVeil {
    /// Dark in a dark room, light in a light one — the panel's rows read against
    /// the veil, not against whatever photograph is behind the glass.
    static let color = Color.adaptive(
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22),
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30)
    )
}

/// The panel's trailing edge, where it is dragged wider or narrower — and, past
/// its narrowest, closed.
private struct SidebarResizeHandle: View {
    @State private var settings = AppSettings.shared
    @State private var startWidth: CGFloat?

    /// How far past the minimum a drag has to go for letting go to close the
    /// sidebar instead of springing back.
    private static let closeOvershoot: CGFloat = 90

    var body: some View {
        Color.clear
            .frame(width: ShellMetrics.resizeHandleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? settings.sidebarWidth
                        if startWidth == nil { startWidth = start }
                        settings.sidebarWidth = start + value.translation.width
                    }
                    .onEnded { value in
                        let start = startWidth ?? settings.sidebarWidth
                        startWidth = nil
                        let proposed = start + value.translation.width
                        if proposed < ShellMetrics.sidebarMinWidth - Self.closeOvershoot {
                            ShellActions.setSidebarShown(false)
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

// MARK: - The sidebar header

/// The panel's top row, level with the traffic lights: room for the lights,
/// then the toggle and the create menu at the trailing end — Noodle's and
/// Craft's arrangement.
private struct PanelHeaderRow: View {
    var layout: ShellLayout

    var body: some View {
        HStack(spacing: Spacing.base) {
            // The lights are the window's, positioned in window space; this is
            // only the room they take inside the panel.
            Color.clear
                .frame(width: ShellMetrics.trafficLightsClearance(layout.style) - layout.panelInset)
            Spacer(minLength: 0)
            if !layout.isTakenOver {
                HeaderCircleButton(systemImage: "sidebar.leading", label: "Hide Sidebar") {
                    ShellActions.toggleSidebar()
                }
                CreateMenu()
            }
        }
        .padding(.trailing, 10)
        .frame(height: layout.sidebarHeaderHeight)
        // **No drag strip here.** This row is the panel's safe-area inset,
        // drawn OVER the pages — and the server's name, which a page draws up
        // into this band, is under it: a strip here took every click meant
        // for the name. The panel's own background carries the strip instead
        // (`SidebarPanel`), under everything that can be pressed.
    }
}

/// What the `+⌄` makes.
struct CreateMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HeaderCreateMenu(label: "Create") {
            Button("New Message…", systemImage: "square.and.pencil") {
                NewMessageRequest.shared.isShown = true
            }
            Button("Add Friend…", systemImage: "person.badge.plus") {
                AddFriendRequest.shared.isShown = true
            }
            Button("New Folder…", systemImage: "folder.badge.plus") {
                DirectMessageFolders.shared.requestNewFolder()
            }
            Divider()
            Button("Add a Server…", systemImage: "plus.circle") {
                model.joinServerSheet = JoinServerSheetState()
            }
            Button("Explore Discoverable Servers", systemImage: "safari") {
                model.toggleDiscovery()
            }
        }
    }
}

// MARK: - The detail column

private struct DetailColumn: View {
    var layout: ShellLayout

    @Environment(AppModel.self) private var model

    var body: some View {
        WorkspacePane(presentation: model.workspacePresentation)
            // The column's title is the window's, for the Window menu and
            // Mission Control — the bar that used to draw it is gone.
            .navigationTitle(model.channelChrome.name)
            .safeAreaInset(edge: .top, spacing: 0) {
                DetailHeader(layout: layout)
            }
            .sheet(isPresented: Binding(
                get: { model.channelChrome.isTopicShown },
                set: { if !$0 { model.openTopicChannelID = nil } }
            )) {
                ChannelTopicSheet()
            }
    }
}
