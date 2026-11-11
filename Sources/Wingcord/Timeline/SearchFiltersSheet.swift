import SwiftUI
import WingcordCore

/// Every filter the route takes, as a form.
///
/// **The same query the field holds, edited a different way.** The tokens in the
/// search field *are* the search — see `AppModel.runSearch()` — so this sheet
/// opens on the query parsed out of them and writes tokens back on Apply.
/// Keeping a structured copy alongside the text is how a sheet and a field end
/// up disagreeing about what is being searched.
///
/// Field for field, this is Discord's own sheet: From, In, Has, Mentions, Date,
/// Author Type, Pinned — and the Date list is a list because that sheet has an
/// "Add date" button, even though the route has exactly two date parameters. See
/// `MessageSearchQuery.dateBounds`.
struct SearchFiltersSheet: View {
    /// The query as the field currently reads.
    var query: MessageSearchQuery
    /// People and channels worth offering, resolved by the caller so this never
    /// touches the store.
    var people: [SearchFilterOption]
    var channels: [SearchFilterOption]
    var apply: (MessageSearchQuery) -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @State private var draft: MessageSearchQuery

    private static let width: CGFloat = 480
    private static let maximumHeight: CGFloat = 700

    init(
        query: MessageSearchQuery,
        people: [SearchFilterOption],
        channels: [SearchFilterOption],
        apply: @escaping (MessageSearchQuery) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.query = query
        self.people = people
        self.channels = channels
        self.apply = apply
        self.dismiss = dismiss
        // **Edited on a copy.** The sheet is cancellable, and a form that wrote
        // through would apply half a change to somebody who backed out of it.
        _draft = State(initialValue: query)
    }

    /// **Grouped into cards, as a settings pane is** (`INVARIANTS.md`, "a
    /// settings pane is cards and plain words"): who, where, what it holds,
    /// when, and the two rarer questions. Each card's rows carry what is chosen
    /// as chips beside the control that chooses it, so the sheet reads as the
    /// search it will run.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SearchFilterCard {
                        peopleRow("From", detail: "Sent by any of these people", path: \.authorIDs)
                        SearchFilterDivider()
                        peopleRow("Mentions", detail: "Mentions any of these people", path: \.mentionIDs)
                    }
                    if draft.scope.guildID != nil {
                        SearchFilterCard { channelRow }
                    }
                    SearchFilterCard {
                        SearchFilterTitle(title: "Has", detail: "Includes any of these kinds of content")
                        SearchToggleFlow(
                            options: MessageSearchHas.allCases.map {
                                .init(id: $0.rawValue, title: $0.title, symbolName: $0.symbolName)
                            },
                            selection: Set(draft.has.map(\.rawValue)),
                            toggle: { raw in
                                guard let value = MessageSearchHas(rawValue: raw) else { return }
                                if draft.has.contains(value) { draft.has.remove(value) } else { draft.has.insert(value) }
                            }
                        )
                    }
                    SearchFilterCard { dateField }
                    SearchFilterCard {
                        authorTypeField
                        SearchFilterDivider()
                        pinnedField
                    }
                }
                .padding(.horizontal, Spacing.group)
                .padding(.top, 2)
                .padding(.bottom, Spacing.group)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maximumHeight)
        .animation(motion.standard, value: draft)
    }

    private var header: some View {
        ModalHeader(title: "Filters", close: dismiss)
    }

    // MARK: People and channels

    private func peopleRow(
        _ title: String,
        detail: String,
        path: WritableKeyPath<MessageSearchQuery, [UserID]>
    ) -> some View {
        let chosen = draft[keyPath: path].map { id in
            people.first { $0.id == id.rawValue }
                ?? SearchFilterOption(id: id.rawValue, title: "Someone", monogram: "?")
        }
        return SearchPickRow(
            title: title,
            detail: detail,
            options: people,
            chosen: chosen,
            emptyMenu: "Nobody here yet",
            toggle: { toggle($0, in: path) }
        )
    }

    private var channelRow: some View {
        let chosen = draft.channelIDs.map { id in
            channels.first { $0.id == id.rawValue }
                ?? SearchFilterOption(id: id.rawValue, title: "A channel", symbolName: "number")
        }
        return SearchPickRow(
            title: "In",
            detail: "Sent in any of these channels",
            options: channels,
            chosen: chosen,
            emptyMenu: "No channels to search",
            toggle: { toggleChannel($0) }
        )
    }

    // MARK: Date

    /// **A list, because the sheet has "Add date"** — and every row narrows one
    /// window. See `MessageSearchQuery.dateBounds`.
    private var dateField: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .firstTextBaseline) {
                SearchFilterTitle(title: "Date", detail: "When the message was sent")
                Spacer(minLength: Spacing.base)
                SearchCapsuleButton(title: "Add Date", symbolName: "plus") {
                    draft.dates.append(.during(Calendar.current.startOfDay(for: .now)))
                }
            }
            ForEach(Array(draft.dates.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: Spacing.base) {
                    SegmentedPicker(
                        options: [.init(0, "Before"), .init(2, "During"), .init(1, "After")],
                        selection: kindBinding(at: index)
                    )
                    .fixedSize()
                    DatePicker("", selection: dayBinding(at: index), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Spacer(minLength: 0)
                    Button {
                        draft.dates.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(.title3))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Ink.secondary)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this date")
                    .accessibilityLabel("Remove this date")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func kindBinding(at index: Int) -> Binding<Int> {
        Binding(
            get: {
                switch draft.dates[index] {
                case .before: 0
                case .after: 1
                case .during: 2
                }
            },
            set: { raw in
                guard draft.dates.indices.contains(index) else { return }
                let day = draft.dates[index].day
                draft.dates[index] = switch raw {
                case 0: .before(day)
                case 1: .after(day)
                default: .during(day)
                }
            }
        )
    }

    private func dayBinding(at index: Int) -> Binding<Date> {
        Binding(
            get: { draft.dates.indices.contains(index) ? draft.dates[index].day : .now },
            set: { day in
                guard draft.dates.indices.contains(index) else { return }
                draft.dates[index] = draft.dates[index].withDay(day)
            }
        )
    }

    // MARK: Author type and pinned

    private var authorTypeField: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            SearchFilterTitle(title: "Author Type", detail: "Sent by any of these kinds of author")
            SearchToggleFlow(
                options: MessageSearchAuthorKind.allCases.map {
                    .init(id: $0.rawValue, title: $0.title, symbolName: $0.symbolName)
                },
                selection: Set(draft.authorKinds.map(\.rawValue)),
                toggle: { raw in
                    guard let value = MessageSearchAuthorKind(rawValue: raw) else { return }
                    if draft.authorKinds.contains(value) {
                        draft.authorKinds.remove(value)
                    } else {
                        draft.authorKinds.insert(value)
                    }
                }
            )
        }
    }

    /// Three states, not two: **unset is not the same as false.** "Not pinned"
    /// is a real filter and so is "either", and a two-way switch cannot say the
    /// difference — so it is the system's segmented control, with "Any".
    private var pinnedField: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            SearchFilterTitle(title: "Pinned", detail: "Whether the message is pinned")
            Spacer(minLength: Spacing.base)
            SegmentedPicker(
                options: [.init(-1, "Any"), .init(1, "Pinned"), .init(0, "Not Pinned")],
                selection: Binding(
                    get: { draft.isPinned.map { $0 ? 1 : 0 } ?? -1 },
                    set: { draft.isPinned = $0 < 0 ? nil : $0 == 1 }
                )
            )
            .fixedSize()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            if draft.activeFilterCount > 0 {
                Button("Clear Filters (\(draft.activeFilterCount))") {
                    draft = draft.clearingFilters()
                }
                .buttonStyle(.plain)
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: Spacing.base)
            GlassEffectContainer(spacing: Spacing.snug) {
                HStack(spacing: Spacing.snug) {
                    ModalButton(title: "Cancel", symbolName: "xmark", role: .cancel, action: dismiss)
                    ModalButton(title: "Apply Filters", symbolName: "line.3.horizontal.decrease.circle.fill", role: .act) {
                        apply(draft)
                    }
                }
            }
        }
        .padding(Spacing.margin)
    }

    // MARK: Selection

    private func toggle(_ raw: UInt64, in path: WritableKeyPath<MessageSearchQuery, [UserID]>) {
        let id = UserID(rawValue: raw)
        if let index = draft[keyPath: path].firstIndex(of: id) {
            draft[keyPath: path].remove(at: index)
        } else {
            draft[keyPath: path].append(id)
        }
    }

    private func toggleChannel(_ raw: UInt64) {
        let id = ChannelID(rawValue: raw)
        if let index = draft.channelIDs.firstIndex(of: id) {
            draft.channelIDs.remove(at: index)
        } else {
            draft.channelIDs.append(id)
        }
    }
}

// MARK: - Parts

/// One person or channel the sheet can offer.
struct SearchFilterOption: Hashable, Sendable, Identifiable {
    var id: UInt64
    var title: String
    var detail: String?
    var avatarURL: URL?
    var monogram: String?
    var symbolName: String?
}

/// A group of the sheet's rows, on the sheet's own glass.
private struct SearchFilterCard<Content: View>: View {
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.hoverFill, in: shape)
        .overlay { shape.strokeBorder(Palette.edge) }
    }
}

private struct SearchFilterDivider: View {
    var body: some View {
        Rectangle().fill(Palette.edge).frame(height: 1)
    }
}

/// A row's name and what it asks, in plain words.
private struct SearchFilterTitle: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text(detail)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
        }
    }
}

/// People or channels: the row's name, an "Add" menu, and what is chosen as
/// chips with a ✕ each.
private struct SearchPickRow: View {
    var title: String
    var detail: String
    var options: [SearchFilterOption]
    var chosen: [SearchFilterOption]
    var emptyMenu: String
    var toggle: (UInt64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .center, spacing: Spacing.base) {
                SearchFilterTitle(title: title, detail: detail)
                Spacer(minLength: Spacing.base)
                Menu {
                    if options.isEmpty {
                        Text(emptyMenu)
                    } else {
                        ForEach(options) { option in
                            Button {
                                toggle(option.id)
                            } label: {
                                if chosen.contains(where: { $0.id == option.id }) {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .contentShape(.capsule)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .plainChip(in: .capsule)
                .accessibilityLabel(Text("Add to \(title)"))
            }
            if !chosen.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(chosen) { option in
                        SearchChosenChip(option: option, remove: { toggle(option.id) })
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
        }
    }
}

private struct SearchChosenChip: View {
    var option: SearchFilterOption
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let avatarURL = option.avatarURL {
                AvatarView(url: avatarURL, monogram: option.monogram ?? "?", side: 18)
            } else if let symbolName = option.symbolName {
                Image(symbol: symbolName)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            Text(option.title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(option.title)"))
        }
        .padding(.leading, option.avatarURL == nil ? 9 : 4)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(Palette.accent.opacity(0.18), in: .capsule)
    }
}

/// A small capsule action inside a card.
private struct SearchCapsuleButton: View {
    var title: String
    var symbolName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbolName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .plainChip(in: .capsule)
    }
}

/// A wrapping row of toggle capsules: the kind's symbol, turned into a tick
/// when it is on, in the accent.
private struct SearchToggleFlow: View {
    struct Option: Hashable, Identifiable {
        var id: String
        var title: String
        var symbolName: String
    }

    var options: [Option]
    var selection: Set<String>
    var toggle: (String) -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options) { option in
                let isOn = selection.contains(option.id)
                Button { toggle(option.id) } label: {
                    HStack(spacing: 5) {
                        Image(symbol: isOn ? "checkmark" : option.symbolName)
                            .font(.system(.caption, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(option.title)
                            .font(.system(.subheadline, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.primary))
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    // Filled, never stroked: a one-point rule round a capsule
                    // this small draws a tick at each end.
                    .background {
                        Capsule().fill(isOn ? Palette.accent.opacity(0.2) : Palette.hoverFill)
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .animation(motion.hover, value: isOn)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
