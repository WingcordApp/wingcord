import AppKit
import SwiftUI
import WingcordCore

// MARK: - A forum's controls, on the toolbar row
//
// docs/FORUMS-INVITES.md D1–D5. Everything that used to stand in two rows over the
// board, on the row every page already has:
//
//     [⇅] [ New | Needs Info | Confirmed | All ⌄ ]   ( # bug-reports )   [New Post] [ tools ] (🔍)
//
// **In `DetailHeader` itself, not a row the page draws** as Discover's and Channels
// & Roles' are, because this row has to reach over the post open beside the board.
// A page's own row would stop at the board's edge.

/// How much of the row each thing gets, as plain numbers, so the rule can be pinned
/// by a test and nothing has to measure the tags to know.
nonisolated enum ForumRowFit {
    static let gap: CGFloat = Spacing.base
    static let control: CGFloat = 36
    /// "All", its chevron and a count, at their widest.
    static let allButton: CGFloat = 74
    static let newPost: CGFloat = 112
    static let tagPadding: CGFloat = 28
    static let customEmoji: CGFloat = 20

    struct Answer: Equatable {
        var visibleTags: Int
        var isNewPostCompact: Bool
    }

    /// - Parameters:
    ///   - rowWidth: the row, with its margins off.
    ///   - titleWidth: the name capsule, which stays on the midline.
    ///   - fixedLeading: what's left of the filters: the sidebar's two controls, while it's away.
    ///   - toolsWidth: the tool group at the right.
    ///   - tagWidths: each tag's segment, in order.
    static func answer(
        rowWidth: CGFloat,
        titleWidth: CGFloat,
        fixedLeading: CGFloat,
        toolsWidth: CGFloat,
        tagWidths: [CGFloat],
        canPost: Bool
    ) -> Answer {
        let half = (rowWidth - titleWidth) / 2 - gap
        // The search circle and the tools come first; New Post gives up its word
        // when they won't all fit on their side of the name.
        let rightWithoutPost = toolsWidth + gap + control
        let isCompact = canPost && rightWithoutPost + gap + newPost > half
        let right = rightWithoutPost + (canPost ? gap + (isCompact ? control : newPost) : 0)
        // The name stays on the midline while the right fits its half, and is
        // pushed left when it doesn't: `HeaderBarLayout`.
        let leftSide = min(half, rowWidth - titleWidth - right - 2 * gap)
        let room = leftSide - fixedLeading - control - gap
        return Answer(
            visibleTags: visibleCount(of: tagWidths, in: room),
            isNewPostCompact: isCompact
        )
    }

    /// As many tags as fit in `room`, leaving space for All if any are left over.
    static func visibleCount(of widths: [CGFloat], in room: CGFloat) -> Int {
        let total = widths.reduce(0, +)
        if total <= room { return widths.count }
        var used: CGFloat = 0
        var count = 0
        for width in widths {
            if used + width + gap + allButton > room { break }
            used += width
            count += 1
        }
        return count
    }
}

// MARK: - The left of the row

/// Sort & View and the tags. Steps down to Sort & View alone while a search is open:
/// a search sends only the name, so the tags don't apply to it (`forums search.har`).
struct ForumToolbarFilters: View {
    var channelID: ChannelID
    var visibleTags: Int
    var isSearching: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        let channel = model.channelIndex[channelID]
        let tags = channel?.availableTags ?? []
        let query = model.forumBoard(for: channelID).query
        HStack(spacing: Spacing.base) {
            ForumSortMenu(
                query: query,
                isMedia: channel?.kind == .media,
                hasTags: !tags.isEmpty,
                defaults: channel.map { ForumQuery(defaultsOf: $0) } ?? ForumQuery(),
                setQuery: { model.setForumQuery($0, in: channelID) }
            )
            if !isSearching, !tags.isEmpty {
                if visibleTags > 0 {
                    ForumTagStrip(
                        tags: Array(tags.prefix(visibleTags)),
                        selected: query.tags,
                        toggle: { toggle($0, query: query) }
                    )
                    .transition(.materialize(from: .leading, blurring: false))
                }
                if visibleTags < tags.count {
                    ForumAllTagsButton(
                        title: visibleTags == 0 ? "Tags" : "All",
                        tags: tags,
                        selected: query.tags,
                        toggle: { toggle($0, query: query) },
                        clear: {
                            var next = query
                            next.tags = []
                            model.setForumQuery(next, in: channelID)
                        }
                    )
                    .transition(.materialize(from: .leading, blurring: false))
                }
            }
        }
        .animation(motion.glassMorph, value: isSearching)
    }

    /// A chip toggles rather than replaces: filtering by two tags is the whole
    /// reason `tag_setting` exists.
    private func toggle(_ id: ForumTagID, query: ForumQuery) {
        var next = query
        if next.tags.contains(id) { next.tags.remove(id) } else { next.tags.insert(id) }
        model.setForumQuery(next, in: channelID)
    }
}

/// Sort & View: Discord's own four groups (`sE`), as a real menu with the system's
/// checkmarks, where a hand-built popover drew its own radio buttons.
private struct ForumSortMenu: View {
    var query: ForumQuery
    var isMedia: Bool
    var hasTags: Bool
    var defaults: ForumQuery
    var setQuery: (ForumQuery) -> Void

    private var title: String { isMedia ? "Sort" : "Sort & View" }

    var body: some View {
        Menu {
            Section("Sort by") {
                ForEach(ForumSortOrder.allCases, id: \.self) { order in
                    Toggle(order.title, isOn: choice(query.sortOrder == order) { $0.sortOrder = order })
                }
            }
            // A media channel is always a gallery.
            if !isMedia {
                Section("View as") {
                    ForEach(ForumLayout.allCases, id: \.self) { layout in
                        Toggle(layout.title, isOn: choice(query.layout == layout) { $0.layout = layout })
                    }
                }
            }
            if hasTags {
                Section("Tag Matching") {
                    ForEach(TagMatching.allCases, id: \.self) { matching in
                        Toggle(matching.title, isOn: choice(query.tagMatching == matching) { $0.tagMatching = matching })
                    }
                }
            }
            Divider()
            Button("Reset to default") { setQuery(query.resettingToDefaults(defaults)) }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: ShellMetrics.headerGlyph, weight: .medium))
                .foregroundStyle(InkColor.solid)
                .frame(width: ForumRowFit.control, height: ForumRowFit.control)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: ForumRowFit.control, height: ForumRowFit.control)
        .contentShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(title)
        .accessibilityLabel(Text(title))
    }

    /// A radio row: on writes the choice, and off has nothing to do.
    private func choice(_ isOn: Bool, _ change: @escaping (inout ForumQuery) -> Void) -> Binding<Bool> {
        Binding(
            get: { isOn },
            set: { _ in
                var next = query
                change(&next)
                setQuery(next)
            }
        )
    }
}

/// The rest of the tags, and how many of them are on.
private struct ForumAllTagsButton: View {
    var title: String
    var tags: [ForumTag]
    var selected: Set<ForumTagID>
    var toggle: (ForumTagID) -> Void
    var clear: () -> Void

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Spacing.tight) {
                Text(title)
                if !selected.isEmpty {
                    Text(selected.count, format: .number)
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16)
                        .padding(.vertical, 1)
                        .background(Palette.accent, in: .capsule)
                }
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(.caption2, weight: .bold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(InkColor.solid)
            .padding(.horizontal, Spacing.snug)
            .frame(height: ForumRowFit.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
        .help("All tags")
        .accessibilityLabel(Text("All tags"))
        .accessibilityValue(Text("\(selected.count) selected"))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ForumTagList(tags: tags, selected: selected, toggle: toggle, clear: clear)
        }
    }
}

/// The full tag set, behind All: Discord's Select Tags (`s_`).
private struct ForumTagList: View {
    var tags: [ForumTag]
    var selected: Set<ForumTagID>
    var toggle: (ForumTagID) -> Void
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.base) {
                Text("Select Tags")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(selected.count, format: .number)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16)
                    .padding(.vertical, 2)
                    .background(
                        selected.isEmpty ? AnyShapeStyle(Palette.edgeStrong) : AnyShapeStyle(Palette.accent),
                        in: .capsule
                    )
            }
            FlowLayout(spacing: Spacing.base) {
                ForEach(tags) { tag in
                    Button { toggle(tag.id) } label: {
                        ForumTagChip(tag: tag, isOn: selected.contains(tag.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(tag.id) ? [.isButton, .isSelected] : .isButton)
                }
            }
            Divider()
            Button("Clear all", action: clear)
                .buttonStyle(.plain)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(selected.isEmpty ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Palette.accent))
                .disabled(selected.isEmpty)
        }
        .padding(Spacing.margin)
        .frame(width: 300)
    }
}

// MARK: - The tags: the system's capsule, in multi-select

/// One tag, as its segment wants it.
struct ForumTagSegment: Equatable {
    var id: ForumTagID
    /// A Unicode emoji sits in the words, so the system draws it. A custom one is a
    /// picture beside them.
    var title: String
    var image: NSImage?
    var isOn: Bool

    /// The words' width at the control's font, plus Discord-ish air.
    static func width(of tag: ForumTag) -> CGFloat {
        let words = title(of: tag)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let measured = (words as NSString).size(withAttributes: [.font: font]).width
        return (measured + ForumRowFit.tagPadding + (tag.emoji?.isCustom == true ? ForumRowFit.customEmoji : 0))
            .rounded(.up)
    }

    static func title(of tag: ForumTag) -> String {
        if let emoji = tag.emoji, !emoji.isCustom { return "\(emoji.name) \(tag.name)" }
        return tag.name
    }
}

/// **`NSSegmentedControl`, as Discover's categories are**, in `selectAny`: probed on
/// macOS 27, with emoji in the words and a picture beside them. The selection takes
/// the accent's colour at a little under half, which keeps it reading as glass: the
/// system's own for this mode is a solid blue, and white at any strength flips the
/// ink to black.
private struct ForumTagStrip: View {
    var tags: [ForumTag]
    var selected: Set<ForumTagID>
    var toggle: (ForumTagID) -> Void

    @State private var customEmoji: [ForumTagID: NSImage] = [:]

    var body: some View {
        ForumTagSegments(
            segments: tags.map { tag in
                ForumTagSegment(
                    id: tag.id,
                    title: ForumTagSegment.title(of: tag),
                    image: customEmoji[tag.id],
                    isOn: selected.contains(tag.id)
                )
            },
            widths: tags.map(ForumTagSegment.width(of:)),
            selectionColor: NSColor(Palette.accent).withAlphaComponent(0.5),
            toggle: toggle
        )
        .controlSize(.extraLarge)
        .fixedSize()
        .task(id: tags.compactMap { $0.emoji?.id }) { await loadCustomEmoji() }
    }

    private func loadCustomEmoji() async {
        for tag in tags {
            guard let emoji = tag.emoji, let id = emoji.id, customEmoji[tag.id] == nil,
                  let url = CDN.emoji(id: id, animated: emoji.isAnimated, side: 16)
            else { continue }
            let key = ImageStore.Key(url: url, maximumPixelSize: 32)
            guard let picture = await ImageStore.shared.image(for: key, bucket: .thumbnail) else { continue }
            customEmoji[tag.id] = NSImage(cgImage: picture, size: NSSize(width: 16, height: 16))
        }
    }
}

private struct ForumTagSegments: NSViewRepresentable {
    var segments: [ForumTagSegment]
    var widths: [CGFloat]
    var selectionColor: NSColor
    var toggle: (ForumTagID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .capsule
        control.borderShape = .capsule
        // These pick values, not views.
        control.role = .valueSelection
        control.trackingMode = .selectAny
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.segmentDistribution = .fit
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Before the first layout: the size SwiftUI asks for comes from these.
        apply(to: control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        apply(to: control, coordinator: context.coordinator)
    }

    private func apply(to control: NSSegmentedControl, coordinator: Coordinator) {
        coordinator.segments = segments
        coordinator.toggle = toggle
        if control.segmentCount != segments.count { control.segmentCount = segments.count }
        if control.selectedSegmentBezelColor != selectionColor { control.selectedSegmentBezelColor = selectionColor }
        for (index, segment) in segments.enumerated() {
            if control.label(forSegment: index) != segment.title { control.setLabel(segment.title, forSegment: index) }
            if control.width(forSegment: index) != widths[index] { control.setWidth(widths[index], forSegment: index) }
            if control.image(forSegment: index) !== segment.image {
                control.setImage(segment.image, forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
            if control.isSelected(forSegment: index) != segment.isOn {
                control.setSelected(segment.isOn, forSegment: index)
            }
        }
    }

    /// **Its segments' widths, whatever the control says.** It's wrong both ways: the
    /// first time it's asked, SwiftUI hasn't written the control size and the answer is
    /// too small, which drew the strip over Sort & View and All; and after losing
    /// segments to a narrower window it goes on answering for all of them, which pushed
    /// All over the name.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: widths.reduce(0, +) + 6, height: SearchField.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var segments: [ForumTagSegment] = []
        var toggle: (ForumTagID) -> Void = { _ in }

        /// `selectAny` says only that something changed, so it's found by looking.
        @objc func changed(_ sender: NSSegmentedControl) {
            for (index, segment) in segments.enumerated() where sender.isSelected(forSegment: index) != segment.isOn {
                toggle(segment.id)
            }
        }
    }
}

// MARK: - New Post

/// The one emphasised control here, and only where the reader may post: absent
/// rather than disabled, since a greyed New Post in a read-only forum is an
/// invitation that can only be refused — §5.5.
struct ForumNewPostButton: View {
    var channelID: ChannelID
    var isCompact: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        let hasDraft = model.hasForumPostDraft(in: channelID)
        Button {
            model.beginForumPost(in: channelID)
        } label: {
            HStack(spacing: Spacing.tight) {
                Image(systemName: hasDraft ? "pencil.line" : "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                if !isCompact {
                    Text("New Post")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? 0 : Spacing.snug)
            .frame(width: isCompact ? ForumRowFit.control : nil, height: ForumRowFit.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .emphasisChrome(Palette.accent)
        .fixedSize()
        .help(hasDraft ? "Continue your post" : "New Post")
        .accessibilityLabel(Text(hasDraft ? "Continue your post" : "New Post"))
    }
}

// MARK: - The search

/// The circle at the right that opens into the native field, as on Discover, and
/// searches this forum's posts as it's typed in: the same route the old field used
/// (`forums search.har`). Its one row hands the words to the server's message
/// search, which is what this circle does on every other page.
struct ForumToolbarSearch: View {
    var channelID: ChannelID
    @Binding var isOpen: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isRowLit = false

    /// Wide enough for a title's first words, and Discover's and the header's own.
    private static let width: CGFloat = 240

    private var phrase: String {
        model.threadSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if isOpen || !model.threadSearchText.isEmpty {
                SearchField(
                    prompt: "Search posts",
                    text: Binding(
                        get: { model.threadSearchText },
                        set: { model.setThreadSearch($0, in: channelID) }
                    ),
                    onMove: { _ in isRowLit.toggle() },
                    onSubmit: { if isRowLit { searchMessages() } },
                    takesFocus: true,
                    onCancel: close,
                    onEndEditing: { if model.threadSearchText.isEmpty { isOpen = false } }
                )
                .frame(width: Self.width)
                .overlay(alignment: .topTrailing) { messageRow }
                .transition(.materialize(from: .trailing, blurring: false))
                .onAppear { isOpen = true }
            } else {
                HeaderCircleButton(systemImage: "magnifyingglass", label: "Search posts") {
                    isOpen = true
                }
                .transition(.materialize(from: .trailing, blurring: false))
            }
        }
        .animation(motion.glassMorph, value: isOpen)
        // ⌘F.
        .onChange(of: model.searchFocusRequest) { isOpen = true }
        .onChange(of: channelID) {
            isOpen = false
            isRowLit = false
        }
    }

    @ViewBuilder
    private var messageRow: some View {
        if !phrase.isEmpty {
            Button(action: searchMessages) {
                HStack(spacing: Spacing.base) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                    Text("Search messages for \u{201C}\(phrase)\u{201D}")
                        .font(.system(.subheadline, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: 34)
                .background {
                    if isRowLit {
                        Capsule().fill(Palette.selectionFill).padding(Spacing.tight)
                    }
                }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .frame(width: Self.width + 60)
            .glassEffect(.regular.interactive(), in: .capsule)
            .offset(y: SearchField.height + Spacing.tight)
            .transition(.materialize(from: .top, blurring: false))
        }
    }

    /// Escape: the words go, then the field.
    private func close() {
        model.clearThreadSearch()
        isOpen = false
        isRowLit = false
    }

    private func searchMessages() {
        let words = phrase
        close()
        model.searchMessages(for: words)
    }
}

// MARK: - The guidelines

/// The forum's guidelines, as real selectable text, off a toolbar toggle: they used
/// to stand over the board as an unformatted block. Discord's own is a toggle and a
/// panel (`nJ`).
struct ForumGuidelinesPopover: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Label("Post Guidelines", systemImage: "text.book.closed.fill")
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(Ink.primary)
            ScrollView {
                ProseText(
                    markdown: model.channelIndex[channelID]?.topic ?? "",
                    font: .system(.body),
                    color: InkColor.primary,
                    mentions: model.mentionContext(),
                    onLink: { model.openLink($0) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.margin)
        .frame(width: 380)
    }
}
