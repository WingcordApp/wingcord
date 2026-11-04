import SwiftUI
import WingcordCore

/// The board, while the reader is editing their own profile.
///
/// **The same column, not a second surface.** The Board tab keeps its place and
/// its scroll; what changes is that each tile becomes a card you can add to,
/// annotate, reorder and remove. Discord does the same thing and it is the right
/// call: an editor that opened somewhere else would make the reader check their
/// work by closing it.
///
/// **Every control here writes to the draft and nothing else.** `PUT
/// /users/@me/widgets` replaces the whole board in one request, so a card that
/// saved itself would be racing the other five — and the save bar could not
/// offer Reset. See `ProfileEditor`.
struct BoardEditorPane: View {
    var editor: ProfileEditor
    var board: BoardPresentation?
    var ground: ProfileGround

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var addingWidget = false
    @State private var removing: ProfileWidget?
    /// The widget a drag is currently over, so the gap opens before the drop.
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(editor.widgets) { widget in
                WidgetEditCard(
                    widget: widget,
                    board: board,
                    ground: ground,
                    isDropTarget: dropTarget == widget.id,
                    pending: pending(for: widget.id),
                    update: { update(widget.id, to: $0) },
                    pickImage: { slot in pickImage(for: widget.id, slot: slot) },
                    remove: { removing = widget }
                )
                .draggable(widget.id) {
                    // The drag preview is the card's own title rather than a
                    // snapshot of it: a three-hundred-point card under the
                    // pointer hides the gap it is being dropped into.
                    Text(widget.content.kind?.title ?? "Widget")
                        .font(.system(.subheadline, weight: .semibold))
                        .padding(Spacing.base)
                        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
                }
                .dropDestination(for: String.self) { ids, _ in
                    dropTarget = nil
                    guard let moved = ids.first else { return false }
                    return move(moved, before: widget.id)
                } isTargeted: { targeted in
                    dropTarget = targeted ? widget.id : nil
                }
            }
        }
        .padding(.top, Spacing.base)
        // The reader's own widget pictures, by their own id.
        .environment(\.widgetOwner, model.currentUserID)
        .animation(motion.standard, value: editor.widgets.map(\.id))
        .modal(
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            style: .alert
        ) {
            if let widget = removing {
                ModalAlert(
                    hero: .symbol("square.grid.2x2"),
                    title: "Remove this widget?",
                    message: Text("All data from this widget will be permanently deleted."),
                    actions: [
                        .cancel(),
                        .act("Remove Widget", symbol: "trash", irreversible: true) {
                            editor.widgets.removeAll { $0.id == widget.id }
                        },
                    ]
                )
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Your Widgets")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: Spacing.base)
            Button {
                addingWidget = true
            } label: {
                Label("Add Widget", systemImage: "plus")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 27)
            }
            .buttonStyle(.plain)
            .interactiveChromeOverMedia(in: .capsule)
            // **A flyout off the button, not a sheet over the profile** — the
            // editor's rule (Alex's screenshot 14).
            .popover(isPresented: $addingWidget, arrowEdge: .bottom) {
                AddWidgetFlyout(
                    existing: Set(editor.widgets.compactMap { $0.content.kind }),
                    makesCustomWidgets: model.entitlements.premiumTier == .nitro,
                    add: { kind in
                        // **No id, which is what makes it a create.** The reply
                        // assigns one; until the save lands this card is
                        // identified by a placeholder that cannot collide with a
                        // real snowflake.
                        editor.widgets.append(
                            ProfileWidget(
                                id: ProfileEditor.draftIDPrefix + UUID().uuidString,
                                content: kind.emptyContent
                            )
                        )
                        addingWidget = false
                        Haptics.pop()
                    }
                )
            }
        }
    }

    // MARK: Mutating the draft

    /// The pictures staged for one widget, by slot.
    private func pending(for id: String) -> [PersonalWidgetSlot: Data] {
        var found: [PersonalWidgetSlot: Data] = [:]
        for (key, image) in editor.pendingImages where key.widgetID == id {
            found[key.slot] = image.bytes
        }
        return found
    }

    /// **Held, not uploaded.** See `ProfileEditor.pendingImages`: a file picked
    /// here reaches Discord at Save and nowhere earlier, so Reset takes it back
    /// without leaving anything behind.
    private func pickImage(for id: String, slot: PersonalWidgetSlot) {
        guard let picked = WidgetImagePicker.pick() else { return }
        editor.pendingImages[ProfileEditor.PendingImageKey(widgetID: id, slot: slot)] =
            ProfileEditor.PendingImage(filename: picked.name, bytes: picked.bytes)
    }

    private func update(_ id: String, to content: ProfileWidget.Content) {
        guard let index = editor.widgets.firstIndex(where: { $0.id == id }) else { return }
        editor.widgets[index].content = content
    }

    /// Moves one widget in front of another.
    ///
    /// **The array's order is the board's order** — `PUT /users/@me/widgets`
    /// draws them in the order it is given — so a reorder is this and nothing
    /// else. No index is stored anywhere.
    private func move(_ id: String, before target: String) -> Bool {
        guard id != target,
              let from = editor.widgets.firstIndex(where: { $0.id == id }),
              let to = editor.widgets.firstIndex(where: { $0.id == target })
        else { return false }
        let widget = editor.widgets.remove(at: from)
        editor.widgets.insert(widget, at: to)
        return true
    }
}

// MARK: - One widget

/// One editable widget: its games, their tags, and the line the reader wrote.
private struct WidgetEditCard: View {
    @Environment(AppModel.self) private var model

    var widget: ProfileWidget
    var board: BoardPresentation?
    var ground: ProfileGround
    var isDropTarget: Bool
    var pending: [PersonalWidgetSlot: Data]
    var update: (ProfileWidget.Content) -> Void
    var pickImage: (PersonalWidgetSlot) -> Void
    var remove: () -> Void

    @Environment(\.motion) private var motion
    @State private var isSearching = false

    private var kind: ProfileWidgetKind? { widget.content.kind }
    private var games: [ProfileWidgetGame] { widget.content.games }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            dragHandle
            card
        }
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: -8)
            }
        }
        .animation(motion.hover, value: isDropTarget)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(InkColor.tertiary)
            .frame(width: 16, height: 24)
            .accessibilityLabel(Text("Reorder"))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            titleRow
            if case .personal(let personal) = widget.content {
                // **Saving a custom widget is Nitro's** — without it Discord
                // keeps the copy it already has and takes no edit — so the
                // editor says so and stays still rather than taking edits that
                // would quietly not stick.
                let canEdit = model.entitlements.premiumTier == .nitro
                PersonalWidgetEditor(
                    widget: personal,
                    pending: pending,
                    update: { update(.personal($0)) },
                    pick: pickImage
                )
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.5)
                if !canEdit {
                    Label("Custom widgets need Nitro. Discord keeps yours as it is.", systemImage: "lock.fill")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(InkColor.secondary)
                }
            } else if case .clipsGallery(let clips) = widget.content {
                ClipsGalleryEditor(clips: clips, update: { update(.clipsGallery($0)) })
            } else if let kind, kind != .application {
                ForEach(games) { game in
                    GameEditRow(
                        game: game,
                        cover: cover(for: game),
                        allowsComment: kind == .favouriteGames,
                        update: { replace(game.gameID, with: $0) },
                        remove: { removeGame(game.gameID) }
                    )
                }
                if isSearching {
                    GameSearchField(
                        add: { summary in
                            addGame(summary.id)
                            isSearching = false
                        },
                        cancel: { isSearching = false }
                    )
                }
            } else {
                // An application widget holds no games — it is a linked game's
                // own stats — so there is nothing inside it to edit. It can be
                // reordered and removed and that is all.
                Text("This widget shows your stats from the game.")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
            }
        }
        .padding(Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A card on a profile: the profile's own panel, not glass.
        .background(ground.panelFill, in: .rect(cornerRadius: Radius.glass))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 1) {
                // A personal widget titles itself — its heading is a field the
                // reader types into, so a second heading above it would be the
                // app naming something they have already named.
                if kind != .personal {
                    Text(kind?.title ?? "Widget")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                }
                if let limit = kind?.gameLimit {
                    Text(limit == 1 ? "Choose 1 game" : "Add up to \(limit) games")
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.tertiary)
                }
            }
            Spacer(minLength: 0)
            if canAddGame {
                Button { isSearching = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(InkColor.primary)
                        .frame(width: Metrics.control, height: Metrics.control)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(Text("Add a game"))
            }
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove widget"))
        }
    }

    /// **The cap is the route's, and it is enforced before the button exists.**
    /// Discord rejects an over-long list outright rather than truncating it, so
    /// a `+` that could only produce a failed save is not drawn.
    private var canAddGame: Bool {
        guard let limit = kind?.gameLimit else { return false }
        return games.count < limit && !isSearching
    }

    private func cover(for game: ProfileWidgetGame) -> BoardGame? {
        board?.tiles
            .flatMap(\.games)
            .first { $0.gameID == game.gameID }
    }

    // MARK: Editing the list

    private func rebuilt(_ games: [ProfileWidgetGame]) -> ProfileWidget.Content? {
        switch kind {
        case .favouriteGames: .favouriteGames(games)
        case .currentGames: .currentGames(games)
        case .playedGames: .playedGames(games)
        case .wantToPlayGames: .wantToPlayGames(games)
        // None of these holds games — a personal widget is authored, not
        // filled, and a gallery holds clips.
        case .application, .personal, .clipsGallery, nil: nil
        }
    }

    private func addGame(_ id: ApplicationID) {
        guard !games.contains(where: { $0.gameID == id }),
              let content = rebuilt(games + [ProfileWidgetGame(gameID: id)])
        else { return }
        update(content)
    }

    private func removeGame(_ id: ApplicationID) {
        guard let content = rebuilt(games.filter { $0.gameID != id }) else { return }
        update(content)
    }

    private func replace(_ id: ApplicationID, with game: ProfileWidgetGame) {
        guard let content = rebuilt(games.map { $0.gameID == id ? game : $0 }) else { return }
        update(content)
    }
}

// MARK: - One game inside a widget

private struct GameEditRow: View {
    var game: ProfileWidgetGame
    var cover: BoardGame?
    /// Only the favourite carries a line of prose; the wire takes a comment on
    /// every kind, and Discord offers it on one.
    var allowsComment: Bool
    var update: (ProfileWidgetGame) -> Void
    var remove: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var isTagging = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            artwork
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(cover?.name ?? " ")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                    .redacted(reason: cover?.name == nil ? .placeholder : [])
                if allowsComment { comment }
                tagRow
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.base)
        .background {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(isHovering ? Palette.hoverFill : .clear)
        }
        .overlay(alignment: .topTrailing) { removeButton }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
    }

    @ViewBuilder
    private var artwork: some View {
        if let cover {
            GameCover(game: cover, width: 56, corner: 10)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.skeletonPlate)
                .frame(width: 56, height: 56 / GameArt.coverAspect)
        }
    }

    private var comment: some View {
        TextField(
            "Let everyone know why this is your favourite",
            text: Binding(
                get: { game.comment ?? "" },
                set: { text in
                    var edited = game
                    edited.comment = text
                    update(edited)
                }
            ),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...3)
        .font(.system(.subheadline))
        .padding(Spacing.base)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.skeletonPlate)
        }
    }

    private var tagRow: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(game.tags.enumerated()), id: \.offset) { _, tag in
                RemovableTagChip(tag: tag) {
                    var edited = game
                    edited.tags.removeAll { $0 == tag }
                    update(edited)
                }
            }
            Button { isTagging = true } label: {
                Text("+ Tags")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .overlay {
                        Capsule().strokeBorder(
                            Palette.skeletonInk,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                    }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isTagging, arrowEdge: .bottom) {
                GameTagPicker(
                    tags: game.tags,
                    update: { tags in
                        var edited = game
                        edited.tags = tags
                        update(edited)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var removeButton: some View {
        if isHovering {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))
            .help("Remove Game")
            .transition(.opacity)
            .accessibilityLabel(Text("Remove game"))
        }
    }
}

/// A tag with its own `×`.
private struct RemovableTagChip: View {
    var tag: GameWidgetTag
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(symbol: tag.symbolName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(InkColor.tertiary)
            Text(tag.title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(InkColor.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(tag.title)"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .plainChip(in: .capsule)
    }
}
