import SwiftUI
import WingcordCore

/// The header's message search: a glass circle that opens into a field, with
/// the filter grammar's suggestions under it.
///
/// **The same state the toolbar's search item drove**, with the same rules
/// (INVARIANTS §1 "Typing is not searching"): the first keystroke starts a
/// draft, Return runs it, emptying the field closes it, and Return on a
/// half-typed filter adopts the first suggestion (`submitSearch`).
///
/// **The suggestions are a layer under the field, not a popover.** A popover is
/// a window of its own and takes the keyboard from the field the reader is
/// typing into.
struct HeaderSearch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    @FocusState private var isFocused: Bool
    @State private var isOpen = false
    /// The suggestion the arrow keys have reached. A lit row in a list belongs to
    /// the view (INVARIANTS §2), not to the store.
    @State private var highlighted: Int?

    private static let fieldWidth: CGFloat = 240

    var body: some View {
        Group {
            if isOpen || !model.searchText.isEmpty {
                field
                    .transition(.materialize(from: .trailing, blurring: false))
            } else {
                HeaderCircleButton(systemImage: "magnifyingglass", label: "Search") {
                    open()
                }
                .transition(.materialize(from: .trailing, blurring: false))
            }
        }
        .animation(motion.glassMorph, value: isOpen || !model.searchText.isEmpty)
        // ⌘F, and a thread's own Search item.
        .onChange(of: model.searchFocusRequest) { open() }
    }

    private func open() {
        isOpen = true
        // On the next turn: the field does not exist until this one is drawn.
        DispatchQueue.main.async { isFocused = true }
    }

    private var field: some View {
        HStack(spacing: Spacing.tight + Spacing.hair) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.secondary)
            TextField("Search \(model.searchScopeTitle)", text: text)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($isFocused)
                .onSubmit { submit() }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onExitCommand { close() }
            if !model.searchText.isEmpty {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(width: Self.fieldWidth, height: ShellMetrics.headerControl)
        .glassEffect(.regular, in: .capsule)
        .onChange(of: isFocused) { _, focused in
            if !focused, model.searchText.isEmpty { isOpen = false }
        }
        .overlay(alignment: .topTrailing) {
            if isFocused {
                suggestions
                    .offset(y: ShellMetrics.headerControl + Spacing.tight)
            }
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestions: some View {
        let rows = model.searchSuggestions(for: model.searchText)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, suggestion in
                    Button {
                        adopt(suggestion)
                    } label: {
                        SearchSuggestionRow(suggestion: suggestion)
                            .padding(.horizontal, Spacing.base)
                            .frame(height: 30)
                            .background {
                                if highlighted == index {
                                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                                        .fill(Palette.selectionFill)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.tight + Spacing.hair)
            .frame(width: Self.fieldWidth + 60)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
            .fixedSize(horizontal: false, vertical: true)
            .transition(.materialize(from: .top, blurring: false))
            .onChange(of: rows.count) { highlighted = nil }
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = model.searchSuggestions(for: model.searchText).count
        guard count > 0 else { return .ignored }
        let next = (highlighted ?? (step > 0 ? -1 : count)) + step
        highlighted = min(max(next, 0), count - 1)
        return .handled
    }

    private func adopt(_ suggestion: SearchSuggestion) {
        text.wrappedValue = suggestion.completion
        highlighted = nil
        isFocused = true
    }

    private func submit() {
        let rows = model.searchSuggestions(for: model.searchText)
        if let highlighted, rows.indices.contains(highlighted) {
            adopt(rows[highlighted])
            return
        }
        model.submitSearch()
    }

    private func close() {
        if model.isSearchDrafting { model.closeSearch() }
        model.searchText = ""
        highlighted = nil
        isOpen = false
        isFocused = false
    }

    /// The field's text, with the toolbar item's two side effects: the first
    /// keystroke starts a draft, and emptying the field puts the transcript back.
    private var text: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { text in
                guard !text.isEmpty else {
                    if model.isSearchDrafting { model.closeSearch() }
                    model.searchText = ""
                    return
                }
                if !model.isSearchDrafting { model.toggleSearch() }
                model.searchText = text
            }
        )
    }
}
