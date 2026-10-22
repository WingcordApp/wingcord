import AppKit
import SwiftUI
import WingcordCore

// MARK: - The clips library
//
// docs/CLIPS-PRESENCE.md, D13 / Phase 4.2 — Discord's Clips Home, as a Mac
// window: a sidebar of what there is (everything, clips, recordings,
// screenshots, favourites, then each game), the toolbar's search ("Search
// clips") and Discord's date presets, Recent above the rest while nothing is
// filtered, and a grid. Clicks select as the Finder's do; a double click
// opens the editor; the selection gets Discord's Clips Actions — Share (ten at
// most) and Delete.

/// What the sidebar picks.
enum ClipsSection: Hashable {
    case all, clips, recordings, screenshots, favourites
    /// Discord's "Auto clips": the clips Auto Clips kept.
    case autoClips
    /// Auto Clips waiting to be kept or thrown away (Phase 7.2).
    case review
    case game(String)
}

struct ClipsLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var store = ClipLibraryStore()
    @State private var section: ClipsSection? = .all
    @State private var query = ""
    @State private var sharing: ClipShareRequest?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            Group {
                if let editing = store.editing {
                    ClipEditorView(item: editing, store: store) { sharing = ClipShareRequest(items: [$0]) }
                } else if section == .review {
                    AutoClipsReview(store: store)
                } else {
                    ClipsGrid(store: store, section: section ?? .all) { sharing = ClipShareRequest(items: $0) }
                }
            }
            .navigationTitle(store.editing?.title ?? title)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search clips")
        .toolbar {
            if store.editing == nil {
                ToolbarItem {
                    Menu {
                        Picker("Date", selection: $store.filter.date) {
                            ForEach(ClipLibraryFilter.DateRange.allCases) { range in
                                Text(range.title).tag(range)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Date", systemImage: "calendar")
                    }
                    .help("Show clips from a time")
                }
                ToolbarItem {
                    Button("Capture", systemImage: "record.circle") { model.capture.showBar() }
                        .help("Record or capture the screen")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task(id: model.clipsRevision) { store.reload() }
        .onChange(of: query) { _, text in store.filter.query = text }
        .onChange(of: section, initial: true) { _, section in apply(section ?? .all) }
        .onAppear { openPendingEdit() }
        .onReceive(NotificationCenter.default.publisher(for: ClipsWindow.didRequestEdit)) { _ in openPendingEdit() }
        .sheet(item: $sharing) { request in
            ClipShareSheet(request: request) { sharing = nil }
        }
    }

    private var title: String {
        switch section ?? .all {
        case .all: "Clips"
        case .clips: "Clips"
        case .recordings: "Recordings"
        case .screenshots: "Screenshots"
        case .favourites: "Favourites"
        case .autoClips: "Auto Clips"
        case .review: "To Review"
        case .game(let name): name
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            Section("Library") {
                row(.all, "All Items", "square.grid.2x2", store.items.count)
                row(.clips, "Clips", "film", store.items.count { $0.kind == .clip })
                row(.recordings, "Recordings", "record.circle", store.items.count { $0.kind == .recording })
                row(.screenshots, "Screenshots", "camera.viewfinder", store.items.count { $0.kind == .screenshot })
                row(.favourites, "Favourites", "star", store.items.count { store.isFavourite($0) })
                row(.autoClips, "Auto Clips", "sparkles", store.items.count { $0.autoReason != nil })
            }
            // Only while there is something to decide about.
            if !store.review.isEmpty {
                Section("Auto Clips") {
                    row(.review, "To Review", "tray.full", store.review.count)
                }
            }
            if !store.games.isEmpty {
                Section("Games") {
                    ForEach(store.games, id: \.self) { game in
                        row(.game(game), game, "gamecontroller", store.items.count { $0.game == game })
                    }
                }
            }
        }
    }

    private func row(_ section: ClipsSection, _ title: String, _ symbol: String, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(section)
    }

    private func apply(_ section: ClipsSection) {
        store.editing = nil
        store.filter.kind = .all
        store.filter.favouritesOnly = false
        store.filter.autoOnly = false
        store.filter.game = nil
        switch section {
        case .all: break
        case .clips: store.filter.kind = .clips
        case .recordings: store.filter.kind = .recordings
        case .screenshots: store.filter.kind = .screenshots
        case .favourites: store.filter.favouritesOnly = true
        case .autoClips: store.filter.autoOnly = true
        case .review: break
        case .game(let name): store.filter.game = name
        }
    }

    private func openPendingEdit() {
        guard let url = ClipsWindow.takePendingEdit() else { return }
        store.reload()
        store.editing = store.items.first { $0.url == url }
    }
}

/// What the share sheet is asked to send.
struct ClipShareRequest: Identifiable {
    var items: [ClipLibraryItem]
    var id: [URL] { items.map(\.url) }
}

// MARK: - The grid

private struct ClipsGrid: View {
    var store: ClipLibraryStore
    var section: ClipsSection
    var share: ([ClipLibraryItem]) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: Spacing.group)]

    var body: some View {
        let visible = store.visible
        Group {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("No clips yet", systemImage: "film.stack")
                } description: {
                    Text("Clips from your gaming sessions, your recordings and your screenshots show up here.")
                } actions: {
                    Button("Record or Capture the Screen…") { model.capture.showBar() }
                    Button("Clips Settings") { SettingsWindow.open(.clips) }
                }
            } else if visible.isEmpty {
                // Discord's own words for an empty search (`+M2iLf`, `xkY5xS`).
                ContentUnavailableView(
                    "No clips found", systemImage: "magnifyingglass",
                    description: Text("Try searching for something else.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.group) {
                        if !store.filter.isActive, section == .all, store.items.count > 4 {
                            heading("Recent")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: Spacing.group)],
                                      spacing: Spacing.group) {
                                ForEach(store.recent) { card($0, large: true, order: store.recent) }
                            }
                            heading("All Clips")
                        }
                        LazyVGrid(columns: columns, spacing: Spacing.group) {
                            ForEach(visible) { card($0, large: false, order: visible) }
                        }
                    }
                    .padding(Spacing.group)
                    .padding(.bottom, store.selection.isEmpty ? 0 : 64)
                }
                // A click on nothing clears the selection, as the Finder's.
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { store.selection = [] }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !store.selection.isEmpty {
                selectionBar
                    .padding(.bottom, Spacing.group)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion.panel, value: store.selection.isEmpty)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(.title3, weight: .semibold))
            .foregroundStyle(Ink.primary)
    }

    private func card(_ item: ClipLibraryItem, large: Bool, order: [ClipLibraryItem]) -> some View {
        ClipCard(
            item: item, isFavourite: store.isFavourite(item),
            isSelected: store.selection.contains(item.url), isLarge: large
        )
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture { store.select(item, modifiers: NSEvent.modifierFlags, in: order) }
        .contextMenu { menu(for: item) }
    }

    /// Discord's context menu, whole (OVERLAY.md §"The context menu"), in Mac
    /// words: Share and Edit; Favourite, Copy, Export; Show in Finder; Delete.
    @ViewBuilder
    private func menu(for item: ClipLibraryItem) -> some View {
        let targets = store.selection.contains(item.url) && store.selection.count > 1 ? store.selectedItems : [item]
        Button("Share…", systemImage: "square.and.arrow.up") { share(Array(targets.prefix(ClipLibraryStore.shareLimit))) }
            .disabled(!model.canShareClips || targets.count > ClipLibraryStore.shareLimit)
        if targets.count == 1, item.kind != .screenshot {
            Button("Edit", systemImage: "slider.horizontal.3") { store.editing = item }
        }
        Divider()
        Button(
            store.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites",
            systemImage: store.isFavourite(item) ? "star.slash" : "star"
        ) { store.toggleFavourite(item) }
        Button(item.kind == .screenshot ? "Copy Image" : "Copy Video", systemImage: "doc.on.doc") { copy(item) }
        Button("Export…", systemImage: "square.and.arrow.down") { export(item) }
        Divider()
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            store.delete(Set(targets.map(\.url)))
        }
    }

    private var selectionBar: some View {
        let count = store.selection.count
        return HStack(spacing: Spacing.snug) {
            // Discord's `cSfYIv`.
            Text(count == 1 ? "1 Clip selected" : "\(count) Clips selected")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .padding(.leading, Spacing.snug)
            Button("Share", systemImage: "square.and.arrow.up") { share(store.selectedItems) }
                .buttonStyle(.glass)
                .disabled(count > ClipLibraryStore.shareLimit || !model.canShareClips)
                .help(count > ClipLibraryStore.shareLimit ? "You can only share 10 clips at a time." : "Share these clips")
            Button("Move to Trash", systemImage: "trash", role: .destructive) { store.delete(store.selection) }
                .buttonStyle(.glass)
            Button("Done") { store.selection = [] }
                .buttonStyle(.glass)
        }
        .controlSize(.large)
        .padding(Spacing.base)
        .glassEffect(.regular, in: .capsule)
    }

    private func open(_ item: ClipLibraryItem) {
        if item.kind == .screenshot {
            NSWorkspace.shared.open(item.url)
        } else {
            store.editing = item
        }
    }

    private func copy(_ item: ClipLibraryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item.url as NSURL])
    }

    private func export(_ item: ClipLibraryItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: item.url, to: destination)
    }
}

// MARK: - Auto Clips to review

/// What Auto Clips kept while you played, to keep or throw away — Discord's
/// "Discord has automatically clipped some of these for you."
private struct AutoClipsReview: View {
    var store: ClipLibraryStore

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: Spacing.group)]

    var body: some View {
        if store.review.isEmpty {
            ContentUnavailableView(
                "Nothing to review", systemImage: "tray",
                description: Text("Clips from your gaming session will show up here.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Wingcord automatically clipped these for you.")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Spacer(minLength: Spacing.base)
                        Button("Discard All", role: .destructive) { store.discard(Set(store.review.map(\.url))) }
                        Button("Keep All") { store.keep(Set(store.review.map(\.url))) }
                            .buttonStyle(.borderedProminent)
                    }
                    LazyVGrid(columns: columns, spacing: Spacing.group) {
                        ForEach(store.review) { item in
                            VStack(alignment: .leading, spacing: Spacing.base) {
                                ClipCard(item: item, isFavourite: false, isSelected: false)
                                    .onTapGesture(count: 2) { store.editing = item }
                                HStack {
                                    Button("Discard", role: .destructive) { store.discard([item.url]) }
                                    Spacer()
                                    Button("Keep") { store.keep([item.url]) }
                                        .buttonStyle(.borderedProminent)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(Spacing.group)
            }
        }
    }
}
