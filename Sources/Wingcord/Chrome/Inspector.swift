import AppKit
import SwiftUI
import WingcordCore

// MARK: - The inspector

/// The column beside a conversation, with what was shared in it a click away
/// (REDESIGN.md R11): the people — a server's members, or the other person's
/// profile — then its media, its pins, its links and its files, as Discord's
/// mobile app keeps them.
///
/// **A segmented control of icons with tooltips** — the HIG's switch between
/// views of one inspector — five segments, its own width, under the window's
/// header. The tab is the column's own state: switching conversations brings
/// the people back, since that is what the toggle that opened it asked for.
struct InspectorPane: View {
    enum Base: Hashable {
        case members
        case profile(UserID)
    }

    var base: Base
    var channelID: ChannelID?
    /// The window's chrome above the column — see `WorkspacePane.chromeHeight`.
    var chromeHeight: CGFloat

    @State private var tab = InspectorTab.people

    static let width: CGFloat = Proportions.profileColumnIdeal

    var body: some View {
        VStack(spacing: 0) {
            if tab == .people {
                people
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: chromeHeight + InspectorSegments.height + Spacing.base * 2)
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        // The switch floats at the column's head, over whatever the tab
        // scrolls under it.
        .overlay(alignment: .top) {
            InspectorSegments(tabs: InspectorTab.allCases, peopleTitle: peopleTitle, selection: $tab)
                .padding(.top, chromeHeight + Spacing.base)
                .padding(.horizontal, Spacing.snug)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: channelID) { _, _ in tab = .people }
    }

    private var peopleTitle: String {
        switch base {
        case .members: "Members"
        case .profile: "Profile"
        }
    }

    @ViewBuilder
    private var people: some View {
        switch base {
        case .members:
            // The roster runs under the chrome as before, with the switch's
            // height added to what it keeps clear.
            MemberListContainer(topInset: chromeHeight + InspectorSegments.height + Spacing.base * 2)
        case .profile(let userID):
            VStack(spacing: 0) {
                Color.clear.frame(height: chromeHeight + InspectorSegments.height + Spacing.base)
                DirectMessageProfileContainer(userID: userID)
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        if let channelID {
            switch tab {
            case .people: EmptyView()
            case .media: ChannelMediaGrid(channelID: channelID, width: Self.width)
            case .pins: PinnedMessagesPane(channelID: channelID, columnWidth: Self.width)
            case .links: ChannelLinkList(channelID: channelID)
            case .files: ChannelFileList(channelID: channelID)
            }
        }
    }
}

/// One of the inspector's views.
enum InspectorTab: CaseIterable, Hashable {
    case people
    case media
    case pins
    case links
    case files

    func title(people: String) -> String {
        switch self {
        case .people: people
        case .media: "Media"
        case .pins: "Pins"
        case .links: "Links"
        case .files: "Files"
        }
    }

    var symbolName: String {
        switch self {
        case .people: "person.2.fill"
        case .media: "photo.on.rectangle.angled"
        case .pins: "pin.fill"
        case .links: "link"
        case .files: "doc.fill"
        }
    }
}

/// The inspector's switch: the system's capsule strip (`SegmentedPicker`, as
/// the inbox's), its segments icons named by their tooltips — the HIG's
/// switch between an inspector's views.
struct InspectorSegments: View {
    var tabs: [InspectorTab]
    var peopleTitle: String
    @Binding var selection: InspectorTab

    /// The extra-large strip's height, which the panes below keep clear.
    static let height: CGFloat = 36

    var body: some View {
        SegmentedPicker(
            options: tabs.map { .init($0, $0.title(people: peopleTitle), symbolName: $0.symbolName) },
            selection: $selection,
            fillsWidth: true
        )
        .accessibilityLabel(Text("Inspector"))
    }
}

private nonisolated enum InspectorInk {
    static let tile = Color.relative(dark: 0.08, light: 0.06)
    static let cover = Color.relative(dark: 0.14, light: 0.10)
}

// MARK: - What was shared

/// What a conversation has shared, read from its loaded messages, newest
/// first — the inspector's Media, Links and Files.
///
/// **The loaded window, not the whole history.** Older media is a search route
/// away (`has=image`, `has=link`, `has=file`); what is already in memory costs
/// nothing to show and is what the reader just scrolled past.
nonisolated struct ChannelLibrary: Equatable, Sendable {
    /// An attachment's place: its message and its position there. **Not the
    /// attachment's own id** — a forwarded or re-sent file can carry the same
    /// one twice, and two tiles with one identity collapse into a hole.
    struct Place: Hashable, Sendable {
        var messageID: MessageID
        var index: Int
    }

    struct Media: Identifiable, Hashable, Sendable {
        var id: Place
        var messageID: MessageID
        var attachmentIndex: Int
        var posterURL: URL?
        var isVideo: Bool
        var isSpoiler: Bool
    }

    struct Link: Identifiable, Hashable, Sendable {
        var id: String { "\(messageID.rawValue)|\(url.absoluteString)" }
        var messageID: MessageID
        var url: URL
        var title: String?
        var sentAt: Date
    }

    struct File: Identifiable, Hashable, Sendable {
        var id: Place
        var messageID: MessageID
        var attachmentIndex: Int
        var filename: String
        var size: Int
        var sentAt: Date
    }

    var media: [Media] = []
    var links: [Link] = []
    var files: [File] = []

    static func build(from messages: [Message], posterWidth: CGFloat) -> ChannelLibrary {
        var library = ChannelLibrary()
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        // Each address once, where it was shared last — a link posted every
        // day is one link, not a page of them.
        var seen = Set<String>()
        for message in messages.reversed() {
            for (index, attachment) in message.attachments.enumerated() {
                if let item = MediaItem(attachment, posterWidth: posterWidth) {
                    library.media.append(Media(
                        id: Place(messageID: message.id, index: index),
                        messageID: message.id,
                        attachmentIndex: index,
                        posterURL: item.posterURL,
                        isVideo: item.isVideo,
                        isSpoiler: attachment.isSpoiler
                    ))
                } else {
                    library.files.append(File(
                        id: Place(messageID: message.id, index: index),
                        messageID: message.id,
                        attachmentIndex: index,
                        filename: attachment.filename,
                        size: attachment.size,
                        sentAt: message.sentAt
                    ))
                }
            }
            guard !message.content.isEmpty, let detector else { continue }
            let text = message.content
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, url.scheme == "http" || url.scheme == "https",
                      seen.insert(url.absoluteString).inserted
                else { continue }
                // An unfurl names the page; without one the address is all
                // there is.
                let title = message.embeds.first { $0.url == url.absoluteString }?.title
                library.links.append(Link(messageID: message.id, url: url, title: title, sentAt: message.sentAt))
            }
        }
        return library
    }
}

/// Reads the library for one conversation when its messages move — not on
/// every change in the store — from the loaded transcript and from what search
/// found further back (`SessionController.loadLibraryPage`), and starts that
/// search the first time the tab is opened.
private struct LibraryReader<Content: View>: View {
    var channelID: ChannelID
    var kind: LibraryKind
    var posterWidth: CGFloat
    @ViewBuilder var content: (ChannelLibrary, LibraryPaging) -> Content

    @Environment(AppModel.self) private var model
    @State private var library = ChannelLibrary()

    var body: some View {
        let loaded = model.messages(in: channelID)?.messages ?? []
        let key = LibraryArchiveKey(channelID: channelID, kind: kind)
        let archive = model.libraryArchives[key]
        let archived = archive?.messages ?? []
        let paging = LibraryPaging(
            hasStarted: archive != nil,
            isLoading: archive?.isLoading ?? false,
            isExhausted: archive?.isExhausted(for: kind) ?? false,
            failure: archive?.failure,
            load: { [model, channelID, kind] in model.sessionController.loadLibraryPage(in: channelID, kind: kind) }
        )
        content(library, paging)
            .task(id: LibraryKey(
                channelID: channelID, count: loaded.count, newest: loaded.last?.id, archived: archived.count
            )) {
                library = ChannelLibrary.build(from: Self.merged(loaded, archived), posterWidth: posterWidth)
            }
            // The first page, when the tab is first opened for this
            // conversation; the footer asks for the rest as it scrolls in.
            .task(id: key) {
                if model.libraryArchives[key] == nil { paging.load() }
            }
    }

    /// Both halves, each message once, oldest first — the order `build` reads.
    private static func merged(_ loaded: [Message], _ archived: [Message]) -> [Message] {
        guard !archived.isEmpty else { return loaded }
        var seen = Set(loaded.map(\.id))
        return (loaded + archived.filter { seen.insert($0.id).inserted })
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private struct LibraryKey: Hashable {
        var channelID: ChannelID
        var count: Int
        var newest: MessageID?
        var archived: Int
    }
}

/// Where a tab's search for older items stands, and how to ask for more.
struct LibraryPaging {
    var hasStarted: Bool
    var isLoading: Bool
    var isExhausted: Bool
    var failure: String?
    var load: () -> Void

    /// Whether an empty list means there is nothing: the search has finished
    /// or failed, rather than not yet answered.
    var isSettled: Bool { hasStarted && !isLoading && (isExhausted || failure != nil) }
}

/// The foot of a tab's list: a spinner while a page is coming, the reason when
/// one did not, and — while there is more — the line whose appearing asks for
/// the next page, so the list grows as it is scrolled.
private struct LibraryFooter: View {
    var paging: LibraryPaging
    /// What the tab lists, for the failure's sentence.
    var noun: String

    var body: some View {
        Group {
            if paging.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, Spacing.base)
            } else if let failure = paging.failure {
                VStack(spacing: Spacing.tight) {
                    Text("Couldn't look further back for \(noun). \(failure)")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.tertiary)
                        .multilineTextAlignment(.center)
                    Button("Try Again", action: paging.load)
                        .controlSize(.small)
                }
                .padding(.vertical, Spacing.base)
            } else if !paging.isExhausted {
                Color.clear
                    .frame(height: 1)
                    .onAppear(perform: paging.load)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// What a tab shows when it has nothing: a spinner until the search has
/// answered, then the empty state, with the reason the search gave if it
/// failed.
private struct LibraryEmpty: View {
    var paging: LibraryPaging
    var symbolName: String
    var text: String
    var noun: String

    var body: some View {
        if paging.isSettled {
            VStack(spacing: 0) {
                InspectorEmptyState(symbolName: symbolName, text: text)
                if paging.failure != nil {
                    LibraryFooter(paging: paging, noun: noun)
                        .padding(.horizontal, Spacing.margin)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.group)
        }
    }
}

/// Pictures and videos, three across, newest first. A tile opens the viewer
/// on the message it came from.
struct ChannelMediaGrid: View {
    var channelID: ChannelID
    var width: CGFloat

    @Environment(AppModel.self) private var model

    private static let columns = 3
    private static let gap: CGFloat = 3

    private var side: CGFloat {
        let inner = width - Spacing.snug * 2
        return ((inner - Self.gap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)).rounded(.down)
    }

    var body: some View {
        LibraryReader(channelID: channelID, kind: .media, posterWidth: side) { library, paging in
            if library.media.isEmpty {
                LibraryEmpty(
                    paging: paging,
                    symbolName: "photo.on.rectangle.angled",
                    text: "Pictures and videos shared here will show up here.",
                    noun: "pictures and videos"
                )
            } else {
                ScrollView {
                    // **One stack, stated.** Left as two children of the
                    // scroll view, the footer was never laid out under the
                    // grid (measured: built with its state, never drawn).
                    VStack(spacing: Spacing.base) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(side), spacing: Self.gap), count: Self.columns),
                            spacing: Self.gap
                        ) {
                            ForEach(library.media) { item in
                                MediaTile(item: item, side: side) {
                                    model.openMedia(
                                        messageID: item.messageID,
                                        in: channelID,
                                        attachmentIndex: item.attachmentIndex,
                                        posterWidths: [],
                                        origin: .inspector
                                    )
                                }
                            }
                        }
                        LibraryFooter(paging: paging, noun: "pictures and videos")
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.bottom, Spacing.margin)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct MediaTile: View {
    var item: ChannelLibrary.Media
    var side: CGFloat
    var open: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            Group {
                if item.isSpoiler {
                    // Covered, as the transcript covers it — a cover, not a
                    // blur: a blur of a dark picture on a dark ground is no
                    // tile at all.
                    ZStack {
                        InspectorInk.cover
                        Text("SPOILER")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(Ink.secondary)
                    }
                } else {
                    RemoteImage(url: item.posterURL, side: side) {
                        InspectorInk.tile
                    }
                    .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .padding(5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.10 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text((item.isSpoiler ? "Spoiler, " : "") + (item.isVideo ? "video" : "picture")))
    }
}

/// Every link shared here, newest first: the page's title where an unfurl
/// gave one, and its site.
struct ChannelLinkList: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        LibraryReader(channelID: channelID, kind: .links, posterWidth: 0) { library, paging in
            if library.links.isEmpty {
                LibraryEmpty(
                    paging: paging,
                    symbolName: "link",
                    text: "Links shared here will show up here.",
                    noun: "links"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(library.links) { link in
                            InspectorRow(
                                symbolName: "link",
                                title: link.title ?? link.url.host() ?? link.url.absoluteString,
                                subtitle: link.title == nil ? link.url.absoluteString : (link.url.host() ?? ""),
                                date: link.sentAt,
                                open: { model.openLink(link.url.absoluteString) },
                                reveal: { model.sessionController.jumpToMessage(link.messageID, in: channelID) }
                            )
                        }
                        LibraryFooter(paging: paging, noun: "links")
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.bottom, Spacing.margin)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// Every file shared here that is not a picture or a video.
struct ChannelFileList: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        LibraryReader(channelID: channelID, kind: .files, posterWidth: 0) { library, paging in
            if library.files.isEmpty {
                LibraryEmpty(
                    paging: paging,
                    symbolName: "doc",
                    text: "Files shared here will show up here.",
                    noun: "files"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(library.files) { file in
                            InspectorRow(
                                symbolName: Self.symbol(for: file.filename),
                                title: file.filename,
                                subtitle: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file),
                                date: file.sentAt,
                                open: {
                                    model.downloadAttachment(
                                        messageID: file.messageID,
                                        in: channelID,
                                        attachmentIndex: file.attachmentIndex
                                    )
                                },
                                reveal: { model.sessionController.jumpToMessage(file.messageID, in: channelID) }
                            )
                        }
                        LibraryFooter(paging: paging, noun: "files")
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.bottom, Spacing.margin)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private static func symbol(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "zip", "rar", "7z", "gz", "tar": "doc.zipper"
        case "pdf": "doc.richtext"
        case "mp3", "wav", "flac", "ogg", "m4a": "waveform"
        case "swift", "js", "ts", "py", "json", "txt", "md", "c", "h", "rs", "go": "doc.text"
        default: "doc"
        }
    }
}

/// A link or a file: what it is, where it is from, when — opened by a click,
/// shown in the conversation by its menu.
private struct InspectorRow: View {
    var symbolName: String
    var title: String
    var subtitle: String
    var date: Date
    var open: () -> Void
    var reveal: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(InspectorInk.tile))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isHovered ? Palette.hoverFill : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Show in Conversation", action: reveal)
        }
    }
}

private struct InspectorEmptyState: View {
    var symbolName: String
    var text: String

    var body: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Ink.tertiary)
            Text(text)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.group)
        .frame(maxWidth: .infinity)
    }
}
