import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

/// The avatar's and the banner's flyout: upload a picture, go back to a recent
/// avatar, or take it off.
///
/// **A moving picture is a Nitro perk** — "If you wanna upload a fun animated
/// avatar, you should subscribe to Nitro", in Discord's own words, and a
/// banner is Nitro to begin with. So a GIF, an APNG or a moving WebP is sent as
/// it is where the account may wear one, and as its first frame where it may
/// not — said in the flyout rather than discovered after Save.
///
/// **The bytes are not re-encoded otherwise.** Discord takes the original and
/// does its own resizing; re-compressing first would upload a worse picture
/// than the one chosen.
struct PictureFlyout: View {
    enum Kind { case avatar, banner }

    var kind: Kind
    var editor: ProfileEditor
    var close: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(ProfileFlyouts.self) private var flyouts: ProfileFlyouts?
    @State private var recents: [RecentAvatar] = []
    @State private var isLoadingRecents = true
    @State private var note: String?
    /// Choose GIF's board is up, in place of the choices.
    @State private var choosesGIF = false
    @State private var gifQuery = ""
    /// A picked GIF on its way down from the provider.
    @State private var isFetchingGIF = false

    private var picker: ProfileEditPicker { kind == .avatar ? .avatar : .banner }

    /// The picture waiting to be cropped, if it is this flyout's.
    private var pending: ProfileFlyouts.PendingPicture? {
        flyouts?.pendingPicture.flatMap { $0.picker == picker ? $0 : nil }
    }

    private var capability: ProfileEditCapability { model.profileEditCapability(for: editor.scope) }

    var body: some View {
        if let pending {
            FlyoutScaffold(title: "Edit Image", subtitle: pending.note) {
                if kind == .avatar {
                    // Discord's own alt text for an avatar, sent with it.
                    TextField("Alt text — describe your picture (optional)", text: Binding(
                        get: { editor.avatarDescription },
                        set: { editor.avatarDescription = String($0.prefix(1024)) }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.system(.subheadline))
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, 6)
                    .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row, style: .continuous))
                    .accessibilityLabel(Text("Alt text"))
                }
                PictureCropView(
                    shape: kind == .avatar ? .avatar : .banner,
                    preview: pending.preview,
                    apply: { crop in
                        land(crop.isIdentity ? pending.image : PictureFile.cropped(pending.image, to: crop) ?? pending.image)
                    },
                    skip: { land(pending.image) }
                )
            }
        } else if choosesGIF {
            gifChooser
        } else {
            choices
        }
    }

    // MARK: Choose GIF

    /// Discord's Choose GIF: the GIF board, favourites left out, and a picked
    /// GIF taken down from its provider and through Edit Image like an upload
    /// (build 643186, `672547` — it fetches the GIF rendition and opens the
    /// crop on it).
    private var gifChooser: some View {
        FlyoutScaffold(title: "Choose GIF", subtitle: gifNote, width: 360) {
            Button {
                choosesGIF = false
                gifQuery = ""
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("Back")
            .accessibilityLabel(Text("Back"))
        } content: {
            GIFBoard(query: $gifQuery, showsFavorites: false, onPick: pickGIF)
                .frame(height: 400)
                .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                .overlay {
                    if isFetchingGIF {
                        ZStack {
                            Rectangle().fill(.black.opacity(0.35))
                            ProgressView().controlSize(.regular)
                        }
                        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                        .transition(.opacity)
                    }
                }
                .allowsHitTesting(!isFetchingGIF)
        }
    }

    /// Whether this picture may move: an avatar on Classic or Nitro, a banner
    /// wherever the banner itself may be set.
    private var movesHere: Bool {
        kind == .avatar ? capability.canUseAnimatedAvatar : capability.canUseAnimatedBanner
    }

    /// Said once, at the top — never an upsell.
    private var gifNote: String? {
        guard !movesHere else { return nil }
        return kind == .avatar
            ? "Moving avatars need Nitro, so a GIF is saved as its first frame."
            : "Moving banners need Nitro, so a GIF is saved as its first frame."
    }

    private func pickGIF(_ gif: GIF) {
        guard let url = gif.previewURL, !isFetchingGIF else { return }
        isFetchingGIF = true
        Task {
            defer { isFetchingGIF = false }
            guard let picked = try? await PictureFile.download(url) else {
                note = "Couldn't get that GIF. Try another one."
                choosesGIF = false
                return
            }
            choosesGIF = false
            gifQuery = ""
            prepare(picked)
        }
    }

    /// Choose GIF's tile: four GIFs in a square, still until the pointer is
    /// over them, as Discord's are.
    private var gifTile: some View {
        GIFMosaicTile(gifs: model.gifMosaic) {
            choosesGIF = true
        }
        .task { model.loadGIFMosaic() }
    }

    private var choices: some View {
        FlyoutScaffold(
            title: kind == .avatar ? "Change Avatar" : "Change Banner",
            subtitle: kind == .avatar
                ? "PNG, JPEG, GIF or WebP. Moving ones need Nitro."
                : "A picture across the top of your profile. GIFs move."
        ) {
            HStack(spacing: Spacing.base) {
                sourceTile("Upload Image", symbol: "photo.badge.plus", action: upload)
                gifTile
            }
            // In a server, taking the picture off is going back to the
            // account's own — and it says so.
            Button(removeTitle, systemImage: editor.scope == .account ? "trash" : "arrow.uturn.backward", role: .destructive) {
                if kind == .avatar { editor.avatar = .removed } else { editor.banner = .removed }
                Haptics.pop()
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(!hasPicture)
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if kind == .avatar { recentsSection }
        }
        .task {
            guard kind == .avatar else { return }
            defer { isLoadingRecents = false }
            recents = (try? await model.recentAvatars()) ?? []
        }
    }

    private var removeTitle: String {
        switch (kind, editor.scope) {
        case (.avatar, .account): "Remove Avatar"
        case (.banner, .account): "Remove Banner"
        case (.avatar, .guild): "Use Main Avatar"
        case (.banner, .guild): "Use Main Banner"
        }
    }

    private var hasPicture: Bool {
        switch kind {
        case .avatar: editor.avatar != .removed
        case .banner:
            switch editor.banner {
            case .removed: false
            case .uploaded: true
            case .unchanged: editor.base.bannerURL != nil
            }
        }
    }

    private func sourceTile(
        _ title: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: Spacing.tight) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(role == .destructive ? Palette.destructive : InkColor.primary)
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .background(Palette.skeletonPlate, in: .rect(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("Recent Avatars")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            if isLoadingRecents {
                ProgressView().controlSize(.small)
            } else if recents.isEmpty {
                Text("Discord isn't holding any previous avatars for you.")
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: Spacing.base), count: 5), spacing: Spacing.base) {
                    ForEach(recents) { recentTile($0) }
                }
            }
        }
    }

    private func recentTile(_ avatar: RecentAvatar) -> some View {
        let isChosen = if case .recent(let chosen) = editor.avatar { chosen.id == avatar.id } else { false }
        return Button {
            editor.avatar = .recent(avatar)
            Haptics.pop()
        } label: {
            RemoteImage(
                url: CDN.avatar(userID: editor.userID, hash: avatar.storageHash, side: 48),
                side: 48,
                bucket: .thumbnail
            ) {
                Circle().fill(Palette.skeletonPlate)
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: 48, height: 48)
            .clipShape(.circle)
            .overlay { Circle().strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 2) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(avatar.description ?? "A previous avatar"))
        .help(avatar.description ?? "")
    }

    /// Picks a file, then **Edit Image**: the crop opens in this flyout —
    /// reopened if the file panel closed it — and the result lands in the draft.
    private func upload() {
        let reopen = flyouts?.open
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let picked = PictureFile.read(url)
        else { return }
        prepare(picked, reopening: reopen)
    }

    /// A picked picture — a file or a GIF — made still where the account may
    /// not wear a moving one, and handed to Edit Image.
    private func prepare(_ picked: ImageData, reopening reopen: ProfileFlyouts.Request? = nil) {
        var image = picked
        var said: String?
        if PictureFile.isAnimated(picked), !movesHere,
           let still = PictureFile.still(picked) {
            image = still
            said = ProfileEditCapability.animatedNote
        }
        guard let preview = PictureFile.firstFrame(image), let flyouts else {
            land(image)
            return
        }
        flyouts.pendingPicture = .init(picker: picker, image: image, preview: preview, note: said)
        if flyouts.open == nil, let reopen { flyouts.open = reopen }
    }

    /// The picture into the draft, and the crop put away.
    private func land(_ image: ImageData) {
        switch kind {
        case .avatar: editor.avatar = .uploaded(image)
        case .banner: editor.banner = .uploaded(image)
        }
        note = flyouts?.pendingPicture?.note
        flyouts?.pendingPicture = nil
        Haptics.pop()
    }
}

/// Choose GIF's tile — four GIFs in a square with the GIF mark, still until
/// the pointer is over it.
private struct GIFMosaicTile: View {
    var gifs: [URL]
    var open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            ZStack {
                // **Four, or one across the whole tile** — never quarters
                // standing empty beside a GIF, which read as a picture that
                // failed to scale.
                if gifs.count >= 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { cell(0); cell(1) }
                        GridRow { cell(2); cell(3) }
                    }
                } else {
                    cell(0, side: 160)
                }
                Rectangle().fill(.black.opacity(0.35))
                VStack(spacing: Spacing.tight) {
                    Text("GIF")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white, in: .rect(cornerRadius: 4, style: .continuous))
                    Text("Choose GIF")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .accessibilityLabel(Text("Choose GIF"))
    }

    /// One GIF, cover-cropped into its box — a quarter's 80 points, or the
    /// whole tile's, decoded at the size it is drawn (INVARIANTS §4.6).
    @ViewBuilder
    private func cell(_ index: Int, side: CGFloat = 80) -> some View {
        Color.clear
            .overlay {
                if gifs.indices.contains(index) {
                    let url = gifs[index]
                    RemoteImage(url: url, side: side, bucket: .attachment) {
                        Rectangle().fill(Palette.surfaceRaised)
                    }
                    .aspectRatio(contentMode: .fill)
                    if isHovering {
                        AnimatedDecoration(url: url, side: side, gravity: .resizeAspectFill)
                    }
                } else {
                    Rectangle().fill(Palette.surfaceRaised)
                }
            }
            .clipped()
    }
}

/// A picked picture file, read and inspected.
enum PictureFile {
    static func read(_ url: URL) -> ImageData? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        return ImageData(mimeType: type?.preferredMIMEType ?? "image/png", bytes: bytes)
    }

    /// A GIF off its provider — or off disk, for `--demo`'s own.
    static func download(_ url: URL) async throws -> ImageData {
        if url.isFileURL {
            guard let picked = read(url) else { throw URLError(.cannotOpenFile) }
            return picked
        }
        let (bytes, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 300, !bytes.isEmpty else {
            throw URLError(.badServerResponse)
        }
        // The provider's own word for it where it gave one, the extension
        // otherwise — Discord's client does the same.
        let mime = response.mimeType.flatMap { $0.hasPrefix("image/") ? $0 : nil }
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "image/gif"
        return ImageData(mimeType: mime, bytes: bytes)
    }

    /// More than one frame — a GIF, an APNG, a moving WebP.
    static func isAnimated(_ image: ImageData) -> Bool {
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// The first frame, as a PNG.
    static func still(_ image: ImageData) -> ImageData? {
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return .png(output as Data)
    }
}
