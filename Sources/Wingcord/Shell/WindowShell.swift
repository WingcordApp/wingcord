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
///  2. **The sidebar slides, and the conversation slides with it.** The
///     panel moves on an offset, which re-lays out nothing — and so does the
///     conversation beside it (REDESIGN.md D10): it is pushed along as one
///     piece by a render-time offset, and laid out at its new width exactly
///     once — as a hide begins, so the room it gains slides in from the
///     window's edge, or as a show ends, once what no longer fits has slid
///     off it. That one re-layout the transcript dissolves (`ShellTransition`).
///     Resizing it on every frame instead re-laid the whole column 60 times a
///     second (REDESIGN.md §5, Phase 7: 48–71 ms frames).
///  3. **The chrome is ours, and every control in it is also a menu command**
///     (the HIG's toolbar rule, kept now there is no toolbar).
struct WindowShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var settings = AppSettings.shared
    /// Where the conversation is laid out from, while a slide is between two
    /// arrangements — nil when it follows the layout, which is at rest.
    @State private var laidLeading: CGFloat?
    /// How far the conversation is pushed from where it is laid out.
    @State private var slide = ConversationSlide()

    var body: some View {
        let layout = ShellLayout(
            style: settings.sidebarStyle,
            sidebarWidth: settings.sidebarWidth,
            isSidebarShown: settings.isSidebarShown,
            isTakenOver: model.isColumnTakenOver
        )
        ZStack(alignment: .topLeading) {
            DetailColumn(layout: layout)
                .padding(.leading, laidLeading ?? layout.detailLeading)
                // **The conversation is moved, never re-laid, while the panel
                // travels — and only the conversation.** Offsetting the whole
                // column carried the roster and the header's trailing
                // controls with it: on a hide they were pushed off the
                // window's edge and slid back in. `WorkspacePane` moves its
                // primary pane by this and clips it; the header glides its
                // title (`DetailHeader`).
                .environment(\.conversationSlide, slide)

            SidebarPanel(layout: layout)
                // The animated part of a change of state, keyed on the state
                // and never on the width: a drag on the panel's edge must
                // track the pointer 1:1.
                .animation(motion.reposition, value: ShellMotionKey(layout))
        }
        .onChange(of: ShellMotionKey(layout)) { old, new in
            slideConversation(from: old.detailLeading, to: new.detailLeading)
        }
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
        .modal(item: Binding(
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
        .modal(item: Binding(
            get: { DirectMessageFolders.shared.nameRequest },
            set: { DirectMessageFolders.shared.nameRequest = $0 }
        )) { request in
            FolderNameSheet(request: request)
        }
        .modal(isPresented: Binding(
            get: { AddFriendRequest.shared.isShown },
            set: { AddFriendRequest.shared.isShown = $0 }
        )) {
            AddFriendSheet()
        }
        .modal(isPresented: Binding(
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

    private var isNew: Bool {
        if case .create = request.purpose { return true }
        return false
    }

    private var canCommit: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        FormSheet(
            title: isNew ? "New Folder" : "Rename Folder",
            subtitle: Text("Folders keep conversations together. They stay on this Mac."),
            confirmTitle: isNew ? "Create" : "Rename",
            canConfirm: canCommit,
            width: 380,
            confirmSymbol: isNew ? "folder.badge.plus" : "pencil",
            confirm: commit
        ) {
            ModalTextField(placeholder: "Folder name", text: $name, symbolName: "folder", onSubmit: commit)
        }
        .onAppear { name = request.initialName }
    }

    private func commit() {
        guard canCommit else { return }
        DirectMessageFolders.shared.complete(request, name: name)
    }
}

extension WindowShell {
    /// Pushes the conversation from one leading edge to the other along with
    /// the panel — `reposition`, the panel's own class, so the two move as one.
    ///
    /// **Laid out once, at whichever end hides the change.** Gaining room (a
    /// hide), it takes its new width at once and is pushed back from where it
    /// stood, so the room it gained comes in from the window's edge as it
    /// travels. Losing room (a show), it keeps its width while it travels — what
    /// no longer fits goes off the window's edge — and takes the narrower one as
    /// the panel lands. Under Reduce Motion the panel and the column change
    /// place without travel, as every arrangement here does.
    private func slideConversation(from old: CGFloat, to new: CGFloat) {
        let distance = new - old
        var settle = Transaction()
        settle.disablesAnimations = true
        guard abs(distance) >= 1, !motion.reduceMotion else {
            withTransaction(settle) {
                laidLeading = nil
                slide = ConversationSlide()
            }
            return
        }
        // The re-layout that follows is the shell rearranging, not a resize.
        ShellTransition.begin()
        // **One write, and the animated value is a progress.** The offset
        // used to be set to where the conversation stood and then animated
        // back to zero — two writes to one value in one event, which SwiftUI
        // coalesces: the animation ran from the value last DRAWN, zero, to
        // zero, and the conversation sat at its new place under the panel for
        // the whole slide. Its ends are fixed here instead and only `progress`
        // animates, from the zero it rests at.
        if distance < 0 {
            // Gaining room: laid out wide now, pushed back to where it stood.
            withTransaction(settle) { laidLeading = nil }
            withAnimation(motion.reposition, completionCriteria: .logicallyComplete) {
                slide = ConversationSlide(from: -distance, to: 0, progress: 1)
            } completion: {
                withTransaction(settle) { slide = ConversationSlide() }
            }
        } else {
            // Losing room: kept as it is while it travels, laid narrower when
            // the panel lands.
            withTransaction(settle) { laidLeading = old }
            withAnimation(motion.reposition, completionCriteria: .logicallyComplete) {
                slide = ConversationSlide(from: 0, to: distance, progress: 1)
            } completion: {
                ShellTransition.begin()
                withTransaction(settle) {
                    laidLeading = nil
                    slide = ConversationSlide()
                }
            }
        }
    }
}

/// What changes the shell's arrangement as one gesture. The width is
/// deliberately absent — see `WindowShell`.
struct ShellMotionKey: Equatable {
    var style: SidebarStyle
    var isSidebarShown: Bool
    var isTakenOver: Bool
    /// Where the conversation begins in this arrangement — carried for the
    /// slide, and not compared: a drag on the panel's edge moves it 1:1.
    var detailLeading: CGFloat

    init(_ layout: ShellLayout) {
        style = layout.style
        isSidebarShown = layout.isSidebarShown
        isTakenOver = layout.isTakenOver
        detailLeading = layout.detailLeading
    }

    static func == (lhs: ShellMotionKey, rhs: ShellMotionKey) -> Bool {
        lhs.style == rhs.style && lhs.isSidebarShown == rhs.isSidebarShown && lhs.isTakenOver == rhs.isTakenOver
    }
}

/// How far the conversation is pushed from where it is laid out while the
/// sidebar travels — `WindowShell.slideConversation` — as two fixed ends and
/// the progress between them, which is the only part that animates
/// (`ConversationSlide.Offset`). At rest it is all zeros.
struct ConversationSlide: Equatable, Sendable {
    var from: CGFloat = 0
    var to: CGFloat = 0
    var progress: CGFloat = 0

    var isMoving: Bool { from != 0 || to != 0 }

    /// Moves a view by the slide, interpolating `progress` alone, so a slide
    /// whose ends change in the same transaction still travels between them.
    struct Offset: ViewModifier, Animatable {
        var slide: ConversationSlide

        nonisolated var animatableData: CGFloat {
            get { slide.progress }
            set { slide.progress = newValue }
        }

        func body(content: Content) -> some View {
            content.offset(x: slide.from + (slide.to - slide.from) * slide.progress)
        }
    }
}

extension EnvironmentValues {
    /// The conversation's slide while the sidebar travels. See
    /// `ConversationSlide`.
    @Entry var conversationSlide = ConversationSlide()
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
            .modal(isPresented: Binding(
                get: { model.channelChrome.isTopicShown },
                set: { if !$0 { model.openTopicChannelID = nil } }
            )) {
                ChannelTopicSheet()
            }
    }
}
