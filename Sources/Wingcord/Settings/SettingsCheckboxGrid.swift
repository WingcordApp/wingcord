import SwiftUI

/// A short list of independent switches, two to a row.
///
/// **A checkbox rather than the switch every other row uses, and a grid rather
/// than a stack.** Both follow from what these are: six or fewer members of one
/// *set*, answering one question — which of these do you want — where a
/// `SettingsToggle` answers a question of its own per row. Stacked one per row
/// they read as six unrelated settings and take six rows of a pane that already
/// scrolls; paired, the set reads as a set.
///
/// Generic over the option rather than over a binding per row: the caller holds
/// one `OptionSet` and this asks it about each member, so there is no chance of
/// six bindings pointing at five things.
struct SettingsCheckboxGrid<Option: Hashable & Identifiable>: View {

    struct Item: Identifiable {
        var value: Option
        var title: String
        var id: Option.ID { value.id }

        init(_ value: Option, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    var options: [Item]
    var isOn: (Option) -> Bool
    var set: (Option, Bool) -> Void

    var body: some View {
        // `LazyVGrid` would be the wrong instrument: there are six of these and
        // laziness costs a container that measures its rows separately for a
        // list that fits on screen by construction.
        Grid(horizontalSpacing: Spacing.snug, verticalSpacing: 0) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { item in
                        checkbox(item)
                    }
                    // An odd count leaves the last row half full rather than
                    // stretching one checkbox across the card.
                    if row.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.base)
    }

    private var rows: [[Item]] {
        stride(from: 0, to: options.count, by: 2).map {
            Array(options[$0..<min($0 + 2, options.count)])
        }
    }

    private func checkbox(_ item: Item) -> some View {
        Toggle(isOn: Binding(
            get: { isOn(item.value) },
            set: { set(item.value, $0) }
        )) {
            Text(item.title)
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .tint(SettingsSurface.switchOn)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: SettingsMetrics.controlRowHeight)
    }
}
