import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

// MARK: - Choosing a wallpaper

/// The tiles a wallpaper is chosen from: the theme, the desktop, the built-in
/// scenes, and a picture, a video or one of macOS's own.
///
/// One view for both places a wallpaper is chosen — Settings and a
/// conversation's own Change Background… — so they cannot drift apart.
struct WallpaperPicker: View {
    @Binding var selection: Wallpaper
    /// Set when choosing a file failed, said in words under the grid.
    @Binding var failure: String?

    @State private var isBrowsingSystem = false

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: Spacing.base)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.base) {
            tile(.theme, title: "Theme")
            tile(.desktop, title: "Desktop")
            ForEach(WallpaperPreset.allCases) { preset in
                tile(.preset(preset), title: preset.title)
            }
            if case .image = selection.source { tile(selection.source, title: "Picture") }
            if case .video = selection.source { tile(selection.source, title: "Video") }
            if case .system(let path, _) = selection.source {
                tile(
                    selection.source,
                    title: SystemWallpaper.name(forPath: path)
                        ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                )
            }
            ActionTile(title: "Choose File…", systemImage: "photo.badge.plus") { chooseFile() }
            ActionTile(title: "macOS Wallpapers…", systemImage: "macwindow") { isBrowsingSystem = true }
        }
        .modal(isPresented: $isBrowsingSystem) {
            SystemWallpaperBrowser { wallpaper in
                selection = Wallpaper(source: .system(path: wallpaper.url.path, isVideo: wallpaper.isVideo),
                                      blur: selection.blur, dim: selection.dim)
                isBrowsingSystem = false
            } cancel: {
                isBrowsingSystem = false
            }
        }
    }

    private func tile(_ source: WallpaperSource, title: String) -> some View {
        WallpaperTile(source: source, title: title, isSelected: selection.source == source) {
            selection = Wallpaper(source: source, blur: selection.blur, dim: selection.dim)
        }
    }

    private func chooseFile() {
        Task {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = WallpaperLibrary.readableTypes
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "Use as Background"
            let chosen: URL? = if let window = NSApp.keyWindow {
                await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
            } else {
                panel.runModal() == .OK ? panel.url : nil
            }
            guard let chosen else { return }
            do {
                let source = try WallpaperStore.shared.adopt(chosen)
                selection = Wallpaper(source: source, blur: selection.blur, dim: selection.dim)
                failure = nil
            } catch {
                failure = "Couldn’t copy that file into Wingcord’s own folder."
            }
        }
    }
}

/// One wallpaper, as a small picture of itself with its name under it.
private struct WallpaperTile: View {
    var source: WallpaperSource
    var title: String
    var isSelected: Bool
    var action: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.tight) {
                preview
                    .frame(height: 58)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? Palette.accent : Palette.edge, lineWidth: isSelected ? 2.5 : 1)
                    }
                Text(title)
                    .font(.system(.caption))
                    .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: source) {
            guard let url = source.fileURL else { return }
            thumbnail = await WallpaperThumbnails.shared.thumbnail(for: url, isVideo: source.isVideo)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch source {
        case .theme:
            // The chosen theme's own ground, not the window's: with a picture
            // up the window's ground is the picture's room, and this tile is
            // the way back to the theme.
            ThemeTilePreview()
                .overlay { Image(systemName: "paintpalette").foregroundStyle(InkColor.solid) }
        case .desktop:
            ZStack {
                LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "menubar.dock.rectangle").foregroundStyle(InkColor.solid)
            }
        case .preset(let preset):
            PresetScene(preset: preset)
        case .image, .video, .system:
            ZStack {
                Palette.surfaceRaised
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                if source.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
        }
    }
}

/// A tile that does something rather than being something.
/// The chosen theme's ground, as its gallery tile draws it.
private struct ThemeTilePreview: View {
    @State private var theme = ThemeStore.shared

    var body: some View {
        RoomSwatch(
            ground: ThemeStore.ground(for: theme.choice, customSeed: theme.customSeed, vividness: theme.vividness)
        )
    }
}

private struct ActionTile: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.tight) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.edgeStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(height: 58)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 17))
                            .foregroundStyle(Ink.secondary)
                    }
                Text(title)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Small decodes of wallpaper files, kept for the life of the process.
@MainActor
final class WallpaperThumbnails {
    static let shared = WallpaperThumbnails()
    private var cache: [URL: CGImage] = [:]

    func thumbnail(for url: URL, isVideo: Bool) async -> CGImage? {
        if let cached = cache[url] { return cached }
        let image: CGImage? = if isVideo {
            await WallpaperMedia.videoFrame(at: url, maximumPixelSize: 320)
        } else {
            await Task.detached(priority: .utility) { WallpaperMedia.image(at: url, maximumPixelSize: 320) }.value
        }
        if let image { cache[url] = image }
        return image
    }
}

// MARK: - macOS's own wallpapers

/// The wallpapers already on this Mac, as a grid to pick from.
private struct SystemWallpaperBrowser: View {
    var choose: (SystemWallpaper) -> Void
    var cancel: () -> Void

    @State private var wallpapers: [SystemWallpaper]?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: Spacing.snug)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(title: "macOS Wallpapers", close: cancel)
            Group {
                if let wallpapers, !wallpapers.isEmpty {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Spacing.snug) {
                            ForEach(wallpapers) { wallpaper in
                                SystemWallpaperCell(wallpaper: wallpaper) { choose(wallpaper) }
                            }
                        }
                        .padding(.horizontal, Spacing.group)
                    }
                    .softScrollEdgesVertical()
                } else if wallpapers != nil {
                    ContentUnavailableView(
                        "No Wallpapers Downloaded",
                        systemImage: "photo.on.rectangle",
                        description: Text("Download wallpapers in System Settings › Wallpaper, then come back.")
                    )
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 360)
            HStack {
                ModalButton(title: "Wallpaper Settings…", symbolName: "gearshape", role: .secondary) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
            }
            .padding(Spacing.margin)
        }
        .frame(width: 640, height: 560)
        .task {
            wallpapers = await Task.detached(priority: .userInitiated) { SystemWallpaper.available() }.value
        }
    }
}

private struct SystemWallpaperCell: View {
    var wallpaper: SystemWallpaper
    var action: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.tight) {
                ZStack {
                    Palette.surfaceRaised
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1, orientation: .up)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    if wallpaper.isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
                .frame(height: 96)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                Text(wallpaper.name)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task(id: wallpaper.url) {
            let url = wallpaper.thumbnailURL ?? wallpaper.url
            let isVideo = wallpaper.thumbnailURL == nil && wallpaper.isVideo
            thumbnail = await WallpaperThumbnails.shared.thumbnail(for: url, isVideo: isVideo)
        }
    }
}

// MARK: - Settings › Appearance

/// The app's wallpaper, its blur and dim, and whether it turns the window dark.
struct WallpaperSettingsCard: View {
    @State private var store = WallpaperStore.shared
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                WallpaperPicker(selection: selection, failure: $failure)
                    .padding(SettingsMetrics.cardContentInset)
                if store.global.source.isPicture {
                    CardDivider()
                    SettingsSliderRow(
                        title: "Blur",
                        help: "Softens the picture so the text on top stays easy to read.",
                        value: Binding(
                            get: { store.global.blur },
                            set: { var next = store.global; next.blur = $0; store.setGlobal(next) }
                        ),
                        range: 0...1,
                        step: 0.02,
                        format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                    )
                    CardDivider()
                    SettingsSliderRow(
                        title: "Dim",
                        help: "How much black is laid over the picture.",
                        value: Binding(
                            get: { store.global.dim },
                            set: { var next = store.global; next.dim = $0; store.setGlobal(next) }
                        ),
                        range: 0...0.9,
                        step: 0.02,
                        format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                    )
                }
                if store.global.source != .theme {
                    CardDivider()
                    CardHeaderRow(
                        title: "Colours",
                        help: "Automatic takes the window\u{2019}s colours from the picture, and none over the "
                            + "desktop. My Theme keeps the theme you chose."
                    )
                    SettingsSegmentedControl(
                        selection: $store.colours,
                        options: WallpaperColours.allCases.map { .init($0, $0.title) }
                    )
                }
                CardDivider()
                SettingsToggle(
                    title: "Dark appearance with a wallpaper",
                    help: "Turns the window dark while a picture is behind it, whatever your theme.",
                    isOn: $store.forcesDarkAppearance
                )
            }
            if let failure {
                SettingsFootnote(failure, symbolName: "exclamationmark.triangle")
            } else {
                SettingsFootnote(
                    "Fills the whole window. To give one conversation its own, right-click it "
                        + "\u{203A} Change Background.",
                    symbolName: "photo.on.rectangle.angled"
                )
            }
        }
    }

    private var selection: Binding<Wallpaper> {
        Binding(get: { store.global }, set: { store.setGlobal($0) })
    }
}

// MARK: - A conversation's own

/// Change Background… for one conversation: a preview with two sample bubbles,
/// the picker, and Use App Background to put it back on the app's.
struct ConversationBackgroundSheet: View {
    var channelID: ChannelID
    var title: String
    var close: () -> Void

    @State private var store = WallpaperStore.shared
    @State private var selection: Wallpaper = .theme
    @State private var failure: String?
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(title: "Conversation Background", subtitle: Text(verbatim: title), close: close)
            VStack(alignment: .leading, spacing: Spacing.margin) {
                preview
                WallpaperPicker(selection: $selection, failure: $failure)
                if let failure {
                    Text(failure)
                        .font(.system(.caption))
                        .foregroundStyle(Palette.destructive)
                }
            }
            .padding(.horizontal, Spacing.group)
            GlassEffectContainer(spacing: Spacing.snug) {
                HStack(spacing: Spacing.snug) {
                    if store.hasOwnWallpaper(channelID) {
                        ModalButton(title: "Use App Background", symbolName: "arrow.uturn.backward", role: .secondary) {
                            store.setWallpaper(nil, for: channelID)
                            close()
                        }
                    } else {
                        ModalButton(title: "Cancel", symbolName: "xmark", role: .cancel, action: close)
                    }
                    Spacer(minLength: 0)
                    ModalButton(title: "Apply", symbolName: "checkmark", role: .act) {
                        store.setWallpaper(selection, for: channelID)
                        close()
                    }
                }
            }
            .padding(Spacing.margin)
        }
        .frame(width: 560)
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            selection = store.wallpaper(for: channelID)
        }
    }

    /// The selection behind two sample bubbles — the shape the conversation will
    /// take, not a description of it.
    private var preview: some View {
        ZStack {
            WallpaperPreview(wallpaper: selection)
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text("Make this space your own.")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
                HStack {
                    Spacer()
                    Text("Looks good!")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: .capsule)
                }
            }
            .font(.system(.body))
            .foregroundStyle(.white)
            .padding(Spacing.group)
        }
        .frame(height: 190)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// A wallpaper drawn small, for a preview: the same scene the window draws.
private struct WallpaperPreview: View {
    var wallpaper: Wallpaper

    @State private var poster: CGImage?

    var body: some View {
        ZStack {
            Color.clear.themeGroundOnly()
            switch wallpaper.source {
            case .theme:
                EmptyView()
            case .desktop:
                Color.gray.opacity(0.3)
            case .preset(let preset):
                PresetScene(preset: preset)
                Color.black.opacity(wallpaper.dim)
            case .image, .video, .system:
                Color.clear.overlay {
                    if let poster {
                        Image(decorative: poster, scale: 1, orientation: .up)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .clipped()
                Color.black.opacity(wallpaper.dim)
            }
        }
        .task(id: wallpaper) {
            poster = await WallpaperMedia.poster(of: wallpaper.source, blur: wallpaper.blur)
        }
    }
}
