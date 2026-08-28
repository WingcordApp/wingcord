import SwiftUI

// MARK: - The source list
//
// A search field and eleven rows in four groups. Deliberately NOT a `List`:
//
//   - `List` on macOS brings AppKit's sidebar vibrancy with it, and the whole
//     point of this window is that both columns are ONE material — the source
//     list is the window's own glass, unpainted, and a second material laid over
//     it is immediately visible as a seam down the middle of the window.
//   - Its row insets, selection shape and group spacing are all system values
//     and none of them are the ones being matched here.
//
// Eleven rows is also small enough that laziness costs more than it saves: a
// `LazyVStack` keeps a subview-per-row bookkeeping structure and defers work
// that would have finished in a single pass.

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @Binding var query: String

    @Namespace private var pill
    @Environment(\.motion) private var motion
    @FocusState private var isSearchFocused: Bool
    /// Whether the arrow keys are currently aimed at this list.
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(query: $query, isFocused: $isSearchFocused)
                .padding(.horizontal, SettingsMetrics.sidebarRowInset)
                .padding(.top, SettingsMetrics.searchFieldTop)

            ScrollView(.vertical) {
                // Built once per evaluation rather than recomputed by each
                // `ForEach` phase, and walked by index — `Array(enumerated())`
                // would allocate a second array of pairs to recover an offset the
                // range already carries.
                let groups = visibleGroups
                VStack(alignment: .leading, spacing: SettingsMetrics.sidebarGroupSpacing) {
                    ForEach(groups.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: SettingsMetrics.sidebarRowSpacing) {
                            ForEach(groups[index]) { section in
                                SettingsSidebarRow(
                                    section: section,
                                    isSelected: section == selection,
                                    hasKeyboardFocus: isListFocused,
                                    pill: pill
                                ) {
                                    selection = section
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, SettingsMetrics.sidebarRowInset)
                .padding(.top, SettingsMetrics.sidebarListTopInset)
                .padding(.bottom, SettingsMetrics.sidebarRowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion.glassMorph, value: selection)
            }
            .scrollBounceBehavior(.basedOnSize)
            .softScrollEdgesVertical()
        }
        // The list is clipped rather than allowed to compress: while the divider
        // is being dragged the column is narrower than a row's intrinsic width,
        // and a stack that reflows to fit produces two lines of text per row on
        // the way past. Clipping is what makes the labels slide out of view the
        // way the reference's do.
        .frame(width: SettingsMetrics.sidebarWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
        // Arrow keys move the selection, ⌘F reaches the search field.
        //
        // A `List` would have given both free; this list is hand-rolled because
        // `List` brings AppKit's sidebar vibrancy with it and the whole window is
        // one material. That trade cost the keyboard, so the keyboard is put back
        // here rather than left as a silent regression.
        .focusable()
        // The default effect draws a rectangle around the whole column, which is
        // the wrong SHAPE for a source list — the thing with focus is a row, not
        // a box. Suppressed here and expressed on the selected row instead, which
        // keeps a visible indicator rather than removing one.
        .focusEffectDisabled()
        .focused($isListFocused)
        .onMoveCommand { direction in
            switch direction {
            case .up: step(-1)
            case .down: step(1)
            default: break
            }
        }
        .onKeyPress(keys: ["f"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            isSearchFocused = true
            return .handled
        }
    }

    /// Moves the selection through the rows the search is currently showing —
    /// flattened, because the group boundaries are spacing rather than stops.
    private func step(_ offset: Int) {
        let visible = visibleGroups.flatMap(\.self)
        guard let index = visible.firstIndex(of: selection) else {
            selection = offset >= 0 ? (visible.first ?? selection) : (visible.last ?? selection)
            return
        }
        // Clamped, not wrapped: the end of a list should read as the end.
        let next = min(visible.count - 1, max(0, index + offset))
        selection = visible[next]
    }

    /// The groups, with rows the search excludes removed and empty groups
    /// dropped — so a search never leaves a gap where a group used to be.
    private var visibleGroups: [[SettingsSection]] {
        // `isEmpty` before `trimmingCharacters`: the trim ALLOCATES, and the
        // empty query is not the rare case — it is every selection change, every
        // hover and every window resize. Checking first keeps the common path
        // free of allocation entirely.
        guard !query.isEmpty else { return SettingsSection.groups }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return SettingsSection.groups }
        let needle = trimmed.lowercased()
        return SettingsSection.groups.compactMap { group in
            let kept = group.filter {
                $0.title.lowercased().contains(needle) || $0.keywords.contains(needle)
            }
            return kept.isEmpty ? nil : kept
        }
    }
}

// MARK: - Search field

private struct SettingsSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7.5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 12, height: 12)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(SettingsType.sidebarRow)
                .foregroundStyle(Ink.primary)
                .focused(isFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10.5)
        .frame(height: SettingsMetrics.searchFieldHeight)
        .background(SettingsSurface.searchField, in: .capsule)
        // The field never moves, so it never catches the system's own specular
        // response as it travels — and over a dark wallpaper that leaves a
        // capsule with no edge at all. This is the still-life version.
        .specularEdge(intensity: 0.18)
        .contentShape(.capsule)
        .onTapGesture { isFocused.wrappedValue = true }
    }
}

// MARK: - Row

private struct SettingsSidebarRow: View {
    var section: SettingsSection
    var isSelected: Bool
    /// Whether the list owns the arrow keys. Brightens the pill, so the reader
    /// can see where a key press will land before pressing one.
    var hasKeyboardFocus: Bool
    var pill: Namespace.ID
    var select: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: SettingsMetrics.sidebarIconGap) {
                SettingsIconTile(
                    symbolName: section.symbolName,
                    tint: section.tint,
                    side: SettingsMetrics.sidebarIconSide,
                    radius: SettingsMetrics.sidebarIconRadius
                )
                Text(section.title)
                    .font(isSelected ? SettingsType.sidebarRowSelected : SettingsType.sidebarRow)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.leading, SettingsMetrics.sidebarRowLeading)
            .padding(.trailing, Spacing.base)
            .frame(height: SettingsMetrics.sidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.settingsRect(SettingsMetrics.sidebarRowRadius))
        }
        .buttonStyle(.plain)
        .background {
            // One pill for the whole list, moved between rows rather than a fill
            // faded in and out per row — which is what makes the selection read
            // as travelling instead of as two rows changing colour at once.
            if isSelected {
                (hasKeyboardFocus ? SettingsSurface.rowFocused : SettingsSurface.rowSelected)
                    .clipShape(.settingsRect(SettingsMetrics.sidebarRowRadius))
                    .matchedGeometryEffect(id: "selection", in: pill)
            } else if isHovered {
                SettingsSurface.rowHover
                    .clipShape(.settingsRect(SettingsMetrics.sidebarRowRadius))
            }
        }
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .animation(motion.hover, value: hasKeyboardFocus)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
