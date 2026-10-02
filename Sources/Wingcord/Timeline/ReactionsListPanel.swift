import SwiftUI
import WingcordCore

/// Who reacted — Discord's reactors modal (`112753`), as a layer over the
/// window.
///
/// **A layer, not a `.sheet`**, for the reason the full profile is one: a sheet
/// is a window of its own, and a profile opened from a row here — or the
/// person menu a right-click raises — would come up underneath it. As a layer
/// both stack above it in the same window (the profiles' presenter is applied
/// after this one), and Escape closes whichever is on top: `EscapeLayer`.
///
/// Clear glass over `Palette.modalScrim`: the quick switcher's recipe, for its
/// reason — a list of names over a transcript is unreadable through clear glass
/// alone, and frosting it is the slab §4 exists to avoid.
struct ReactionsListLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// The panel's own size, and the air it keeps from the window's edges.
    /// Discord's is 480 points wide at its "md" size.
    private static let width: CGFloat = 480
    private static let height: CGFloat = 560
    private static let inset: CGFloat = 32

    var body: some View {
        let request = model.reactionsList
        ZStack {
            if let request {
                Button { model.reactionsList = nil } label: {
                    Palette.modalScrim.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .cancelAction(unless: model.isCovered(.reactions))
                .accessibilityLabel(Text("Close reactions"))
                .ignoresSafeArea()
                .transition(.opacity)

                ReactionsListPanel(request: request)
                    .id(request.id)
                    // Its own size where the window has room, and the window
                    // less its margin where it has not.
                    .frame(maxWidth: Self.width, maxHeight: Self.height)
                    .padding(Self.inset)
                    .transition(.materialize)
            }
        }
        .animation(motion.panel, value: request?.id)
    }
}

/// The panel: the reactions down the side, the people who made the chosen one
/// beside them.
private struct ReactionsListPanel: View {
    var request: ReactionsListRequest

    @Environment(AppModel.self) private var model
    @State private var selection: ReactionListing.Key?
    @State private var pages: [ReactionListing.Key: ReactorPage] = [:]

    /// Discord's page: a hundred people a request (`es.WxW`, captured as
    /// `limit=100` in `view reactions.har`).
    static let pageSize = 100

    init(request: ReactionsListRequest) {
        self.request = request
        _selection = State(initialValue: request.selection)
    }

    var body: some View {
        // Read here, so a reaction arriving while the panel is up recounts it.
        let entries = ReactionListing.entries(
            of: model.message(request.messageID, in: request.channelID)?.reactions ?? []
        )
        let current = entries.first { $0.id == selection } ?? entries.first

        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.selectionFill).frame(height: 1)
            HStack(spacing: 0) {
                entryColumn(entries, current: current)
                Rectangle().fill(Palette.selectionFill).frame(width: 1)
                    .padding(.vertical, Spacing.snug)
                if let current {
                    peopleColumn(current)
                } else {
                    Spacer()
                }
            }
        }
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.card))
        .specularEdge(in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // **Discord closes the list when nothing is left in it** — the last
        // reaction taken off, or the message gone.
        .onChange(of: entries.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { model.reactionsList = nil }
        }
        .task(id: current?.id) {
            guard let current, pages[current.id] == nil else { return }
            await load(current)
        }
    }

    private var header: some View {
        HStack {
            Text("Reactions")
                .font(.system(.headline))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: 0)
            Button { model.reactionsList = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .frame(width: Metrics.control, height: Metrics.control)
                    // A region inside the panel's material, not a body of its
                    // own — glass on glass is §4's first rule.
                    .background(Circle().fill(Palette.hoverFill))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel(Text("Close reactions"))
        }
        .padding(Spacing.margin)
    }

    // MARK: The reactions

    private func entryColumn(_ entries: [ReactionListing], current: ReactionListing?) -> some View {
        ScrollView {
            VStack(spacing: Spacing.tight) {
                ForEach(entries) { entry in
                    ReactionEntryButton(entry: entry, isSelected: entry.id == current?.id) {
                        selection = entry.id
                    }
                }
            }
            .padding(Spacing.snug)
        }
        .scrollIndicators(.hidden)
        .softScrollEdgesVertical()
        .frame(width: 124)
    }

    // MARK: The people

    private func peopleColumn(_ entry: ReactionListing) -> some View {
        let page = pages[entry.id] ?? ReactorPage()
        let guildID = model.channelIndex.guildID(of: request.channelID)
        // Discord's own test (`eu`): more to fetch while the count is ahead of
        // what has been fetched — and here also while the last page was full.
        let hasMore = !page.isExhausted && entry.count > page.users.count
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(page.users, id: \.self) { userID in
                    ReactorRow(
                        userID: userID,
                        guildID: guildID,
                        canRemove: model.canRemoveReaction(
                            of: userID, on: request.messageID, in: request.channelID
                        ),
                        remove: { remove(userID, from: entry) }
                    )
                    .onAppear {
                        guard userID == page.users.last, hasMore else { return }
                        Task { await load(entry) }
                    }
                }
                if page.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: ReactorRow.height)
                }
            }
            .padding(Spacing.base)
        }
        .scrollIndicators(.automatic)
        .softScrollEdgesVertical()
        .frame(maxWidth: .infinity)
        .id(entry.id)
    }

    /// The next page of `entry`'s people, after the last one there is.
    private func load(_ entry: ReactionListing) async {
        let before = pages[entry.id] ?? ReactorPage()
        guard !before.isLoading, !before.isExhausted else { return }
        pages[entry.id, default: ReactorPage()].isLoading = true
        let fetched = await model.sessionController.reactors(
            of: entry.emoji,
            kind: entry.kind,
            on: request.messageID,
            in: request.channelID,
            limit: Self.pageSize,
            after: before.users.last
        )
        var page = pages[entry.id] ?? ReactorPage()
        page.isLoading = false
        if let fetched {
            let known = Set(page.users)
            page.users += fetched.filter { !known.contains($0) }
            page.isExhausted = fetched.count < Self.pageSize
        } else {
            // A refusal is not retried from a scroll: the list stops where it
            // is rather than asking again on every row that appears.
            page.isExhausted = true
        }
        pages[entry.id] = page
    }

    private func remove(_ userID: UserID, from entry: ReactionListing) {
        Task {
            guard await model.removeReaction(
                of: userID, entry, on: request.messageID, in: request.channelID
            ) else { return }
            pages[entry.id]?.users.removeAll { $0 == userID }
        }
    }
}

/// One entry's people, as far as they have been fetched.
private struct ReactorPage {
    var users: [UserID] = []
    var isLoading = false
    /// The last page came back short, or not at all.
    var isExhausted = false
}

/// One reaction down the side: its emoji and its count — Discord's `eo`.
private struct ReactionEntryButton: View {
    var entry: ReactionListing
    var isSelected: Bool
    var select: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    /// A super reaction's own colours — the chip's palette — for its fill,
    /// its edge and its count, as Discord styles the entry.
    private var palette: SuperReactionPalette.Style? {
        guard entry.kind == .burst else { return nil }
        return SuperReactionPalette(colors: entry.burstColors)?.style(isLight: colorScheme == .light)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: Spacing.base) {
                // Discord plays an animated one here and in the flyout alike.
                ExpressionGlyph(emoji: entry.emoji, side: 24, plays: true)
                    .accessibilityHidden(true)
                Text(entry.count, format: .number.grouping(.never))
                    .font(.system(.subheadline, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.map { Color(hex: $0.accent) } ?? InkColor.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 36)
            .background { background }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .help(ReactionTooltipText.name(of: entry.emoji))
        .accessibilityLabel(Text(
            "\(ReactionTooltipText.name(of: entry.emoji)), \(entry.count) \(entry.kind == .burst ? "super reactions" : "reactions")"
        ))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let palette {
            let tint = Color(hex: palette.background)
            shape
                .fill(tint.opacity(isSelected ? palette.opacity : 0.025))
                .strokeBorder(tint.opacity(isSelected ? min(1, palette.opacity * 1.1) : 0.05), lineWidth: 1)
        } else if isSelected {
            shape.fill(Palette.selectionFill)
        } else if isHovering {
            shape.fill(Palette.hoverFill)
        }
    }
}

/// One person who reacted: their face, their name and their username —
/// Discord's `ed`. A click opens their profile, a right-click their menu.
private struct ReactorRow: View {
    var userID: UserID
    var guildID: GuildID?
    var canRemove: Bool
    var remove: () -> Void

    /// Discord's row: 52 points.
    static let height: CGFloat = 52
    private static let avatarSide: CGFloat = 32

    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        let user = model.users[userID]
        let name = model.voiceName(of: userID, inGuild: guildID)
        HStack(spacing: Spacing.snug) {
            AvatarView(
                url: model.avatarURL(forUserID: userID, inGuild: guildID, side: Self.avatarSide),
                monogram: user?.monogram ?? "?",
                side: Self.avatarSide
            )
            VStack(alignment: .leading, spacing: 0) {
                StyledDisplayName(
                    text: name,
                    style: user.flatMap { model.cosmetics(of: $0)?.displayNameStyle },
                    textStyle: .body,
                    weight: .medium,
                    // One name moving in a list of a hundred is the one under
                    // the pointer — the direct-message list's rule.
                    animates: isHovering,
                    maximumWidth: 280
                )
                .foregroundStyle(InkColor.primary)
                Text(user?.username ?? "")
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if canRemove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(InkColor.secondary)
                        .frame(width: Metrics.control, height: Metrics.control)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Remove Reaction")
                // Under the pointer only, as Discord shows it. VoiceOver has
                // it as the row's named action instead.
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Self.height)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.hoverFill)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            model.openProfile(userID, anchor: .zero, depth: .full)
        }
        .onSecondaryClick { anchor in
            model.openUserMenu(for: userID, anchor: anchor, inGuild: guildID)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        // One element — the name and the username — whose default action
        // opens the profile, with the removal as a named action beside it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(name), \(user?.username ?? "")"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Opens their profile"))
        .accessibilityAction { model.openProfile(userID, anchor: .zero, depth: .full) }
        .accessibilityActions {
            if canRemove { Button("Remove Reaction", action: remove) }
        }
    }
}
