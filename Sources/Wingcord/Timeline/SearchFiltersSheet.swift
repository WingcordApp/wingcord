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

    private static let width: CGFloat = 460
    private static let maximumHeight: CGFloat = 620

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    SearchFilterPicker(
                        title: "From",
                        detail: "Sent by any of the selected people",
                        placeholder: "Anyone",
                        options: people,
                        selection: Set(draft.authorIDs.map(\.rawValue)),
                        toggle: { toggle($0, in: \.authorIDs) }
                    )
                    if draft.scope.guildID != nil {
                        SearchFilterPicker(
                            title: "In",
                            detail: "Sent in any of the selected channels",
                            placeholder: "Any channel",
                            options: channels,
                            selection: Set(draft.channelIDs.map(\.rawValue)),
                            toggle: { toggleChannel($0) }
                        )
                    }
                    hasField
                    SearchFilterPicker(
                        title: "Mentions",
                        detail: "Mentions any of the selected people",
                        placeholder: "Anyone",
                        options: people,
                        selection: Set(draft.mentionIDs.map(\.rawValue)),
                        toggle: { toggle($0, in: \.mentionIDs) }
                    )
                    dateField
                    authorTypeField
                    pinnedField
                }
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.group)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maximumHeight)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        .presentationBackground(.clear)
        .animation(motion.standard, value: draft.dates.count)
    }

    private var header: some View {
        HStack {
            Text("Filters")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    // MARK: Has

    private var hasField: some View {
        SearchFilterSection(title: "Has", detail: "Includes any of the selected kinds of data") {
            SearchChipFlow(
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
    }

    // MARK: Date

    /// **A list, because the sheet has "Add date"** — and every row narrows one
    /// window. See `MessageSearchQuery.dateBounds`.
    private var dateField: some View {
        SearchFilterSection(title: "Date", detail: "When the message was sent") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                ForEach(Array(draft.dates.enumerated()), id: \.offset) { index, clause in
                    HStack(spacing: Spacing.base) {
                        Picker("", selection: kindBinding(at: index)) {
                            Text("Before").tag(0)
                            Text("After").tag(1)
                            Text("During").tag(2)
                        }
                        .labelsHidden()
                        .fixedSize()

                        DatePicker("", selection: dayBinding(at: index), displayedComponents: .date)
                            .labelsHidden()

                        Spacer(minLength: 0)

                        Button {
                            draft.dates.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(.caption))
                                .foregroundStyle(Ink.tertiary)
                                .frame(width: Metrics.control, height: Metrics.control)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove this date")
                    }
                }

                SurfaceQuietButton(title: "Add date", systemImage: "plus") {
                    draft.dates.append(.during(Calendar.current.startOfDay(for: .now)))
                }
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
        SearchFilterSection(title: "Author Type", detail: "Sent by any of the selected kinds of author") {
            SearchChipFlow(
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
    /// difference.
    private var pinnedField: some View {
        SearchFilterSection(title: "Pinned", detail: "Whether the message is pinned") {
            SearchChipFlow(
                options: [
                    .init(id: "true", title: "Pinned", symbolName: "pin.fill"),
                    .init(id: "false", title: "Not pinned", symbolName: "pin.slash"),
                ],
                selection: draft.isPinned.map { [$0 ? "true" : "false"] } ?? [],
                toggle: { raw in
                    let value = raw == "true"
                    draft.isPinned = draft.isPinned == value ? nil : value
                }
            )
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
            SurfaceQuietButton(title: "Cancel", systemImage: nil, action: dismiss)
            SurfaceFilledButton(title: "Apply Filters", systemImage: nil) { apply(draft) }
        }
        .padding(Spacing.group)
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

/// One row of the sheet, with its heading.
struct SearchFilterOption: Hashable, Sendable, Identifiable {
    var id: UInt64
    var title: String
    var detail: String?
    var avatarURL: URL?
    var monogram: String?
    var symbolName: String?
}

private struct SearchFilterSection<Content: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A menu of people or channels, with what is chosen shown as chips.
private struct SearchFilterPicker: View {
    var title: String
    var detail: String
    var placeholder: String
    var options: [SearchFilterOption]
    var selection: Set<UInt64>
    var toggle: (UInt64) -> Void

    var body: some View {
        SearchFilterSection(title: title, detail: detail) {
            Menu {
                if options.isEmpty {
                    Text("Nobody here yet")
                } else {
                    ForEach(options) { option in
                        Button {
                            toggle(option.id)
                        } label: {
                            if selection.contains(option.id) {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.tight) {
                    Text(label)
                        .font(.system(.callout))
                        .foregroundStyle(selection.isEmpty ? Ink.tertiary : Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.control + Spacing.base)
                .background(
                    Palette.surfaceRaised,
                    in: .rect(cornerRadius: Radius.chip, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Ink.quaternary, lineWidth: 1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private var label: String {
        let chosen = options.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return placeholder }
        if chosen.count == 1 { return chosen[0].title }
        return "\(chosen[0].title) and \(chosen.count - 1) more"
    }
}

/// A wrapping row of toggle chips.
private struct SearchChipFlow: View {
    struct Option: Hashable, Identifiable {
        var id: String
        var title: String
        var symbolName: String
    }

    var options: [Option]
    var selection: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        // A grid rather than a hand-rolled flow: the chips are a fixed set of
        // short labels, and an adaptive grid wraps them without measuring.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 118), spacing: Spacing.base)],
            alignment: .leading,
            spacing: Spacing.base
        ) {
            ForEach(options) { option in
                let isOn = selection.contains(option.id)
                Button { toggle(option.id) } label: {
                    HStack(spacing: Spacing.tight) {
                        Image(symbol: option.symbolName)
                            .font(.system(.caption))
                        Text(option.title)
                            .font(.system(.callout))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary))
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: Metrics.control + Spacing.tight)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .fill(isOn ? Palette.accent.opacity(0.16) : Palette.hoverFill)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .strokeBorder(
                                isOn ? AnyShapeStyle(Palette.accent.opacity(0.55))
                                     : AnyShapeStyle(Ink.quaternary),
                                lineWidth: 1
                            )
                    }
                    .contentShape(.rect(cornerRadius: Radius.chip))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
