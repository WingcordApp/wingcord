import SwiftUI
import WingcordCore

/// What the composer becomes once a command has been chosen.
///
/// **Chips before the field, not text inside it.** The state underneath is a
/// leaf and a value per option — see `PendingCommand` — and drawing it as chips
/// is what makes that visible: the reader can see which option they are
/// answering, which they have already answered, and take one back without
/// re-typing the rest. A single text field holding `/8ball question:…` reads the
/// same until somebody's question contains a colon.
///
/// **The chips are regions inside the composer's material, never their own glass
/// bodies.** The bar is already `.regular` glass; a `.glassEffect` here would be
/// glass on glass — `INVARIANTS.md` §4 rule 2 — and the inner surface would have
/// the outer one's blurred output to sample rather than what is behind the
/// window, which reads as a flat lighter slab.
struct CommandComposerBar: View {
    var pending: PendingCommand
    /// Puts the caret back into an option already answered.
    var onEdit: (String) -> Void

    var body: some View {
        HStack(spacing: Spacing.tight) {
            commandChip
            ForEach(pending.arguments) { argument in
                argumentChip(argument)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// `/8ball`. The one chip that is not editable — changing which command this
    /// is means starting a different one, which Escape already does.
    private var commandChip: some View {
        HStack(spacing: Spacing.tight) {
            Text("/\(pending.command.name)")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.solid)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Metrics.commandChipHeight)
        .background(
            Palette.accent.opacity(Self.commandChipOpacity),
            in: .rect(cornerRadius: Radius.row, style: .continuous)
        )
        .accessibilityLabel(Text("Command /\(pending.command.name)"))
        .accessibilityHint(Text("Press Escape to cancel"))
    }

    /// `question: am i good enough` — the name, then what it was filled with.
    ///
    /// One control, and clicking it puts the caret back in that option. There is
    /// no separate delete affordance: a chip you can only remove is a chip you
    /// cannot fix, and re-typing a long answer to change one word is the whole
    /// reason this is not a text field.
    private func argumentChip(_ argument: CommandArgument) -> some View {
        Button {
            onEdit(argument.name)
        } label: {
            HStack(spacing: Spacing.tight) {
                Text(argument.name)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.tertiary)
                Text(argument.value.display)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: Metrics.commandChipHeight)
            .frame(maxWidth: Self.chipMaxWidth, alignment: .leading)
            .background(
                Palette.selectionFill,
                in: .rect(cornerRadius: Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Edit \(argument.name)")
        .accessibilityLabel(Text("\(argument.name), \(argument.value.display)"))
        .accessibilityHint(Text("Edit this value"))
    }

    /// Wide enough for a sentence, short enough that three chips still leave the
    /// field somewhere to be. A long answer truncates in the middle, where the
    /// ends are the part somebody recognises.
    private static let chipMaxWidth: CGFloat = 220
    /// The command chip is tinted, not filled: it is the accent doing the work
    /// the send control's does, at a weight that sits inside a bar rather than
    /// on top of it.
    private static let commandChipOpacity: Double = 0.55
}

// MARK: - The option list

/// The flyout that opens over the composer while an option is being answered.
///
/// **A list only where there is something to pick**, which is the keyboard's
/// whole contract: a list means Return picks, no list means Return commits.
/// Two things fill it —
///
///  - **Choices**, when the application declared a fixed set. The field is then
///    a filter over them, and typing something else is a value the bot rejects.
///  - **A reference picker** — the people in this conversation, the server's
///    channels, its roles — for the option kinds whose value is a snowflake.
///    Typing a name is not a value: the wire wants an id.
///
/// A string or a number is typed, and the panel is its header alone: the
/// option's name, whether it is required, and the sentence its author wrote.
/// Rows under it would be a control that does nothing.
struct CommandOptionList: View {
    var title: String
    var subtitle: String?
    var rows: [CommandOptionRow]
    var selection: Int
    var onPick: (CommandOptionRow) -> Void
    var onHover: (Int) -> Void

    @Environment(\.motion) private var motion
    @Namespace private var selectionNamespace

    private static let maxHeight: CGFloat = 208
    private static let rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !rows.isEmpty { list }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// The option's own name, and the sentence its author wrote for it.
    ///
    /// **The description belongs here, not in the field's placeholder.** A
    /// placeholder vanishes the moment anybody types, which is exactly when they
    /// still want to know what was being asked for.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.top, Spacing.snug)
        .padding(.bottom, rows.isEmpty ? Spacing.snug : Spacing.base)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        optionRow(row, isSelected: index == selection)
                            .id(row.id)
                            .onHover { if $0 { onHover(index) } }
                            .onTapGesture { onPick(row) }
                    }
                }
                .padding(.horizontal, Spacing.base)
                .padding(.bottom, Spacing.base)
            }
            .scrollIndicators(.never)
            .softScrollEdgesVertical()
            .frame(maxHeight: Self.maxHeight)
            .onChange(of: selection) { _, index in
                guard rows.indices.contains(index) else { return }
                withAnimation(motion.standard) { proxy.scrollTo(rows[index].id) }
            }
        }
    }

    private func optionRow(_ row: CommandOptionRow, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.base) {
            if let symbol = row.symbolName {
                Image(symbol: symbol)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 16)
            }
            Text(row.title)
                .font(.system(.subheadline))
                .foregroundStyle(isSelected ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
                .lineLimit(1)
            if let detail = row.detail, !detail.isEmpty {
                Text(detail)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.quaternary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if row.isRequired {
                Text("required")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.quaternary)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Self.rowHeight)
        .matchedSelection(isSelected: isSelected, namespace: selectionNamespace)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.title))
        .accessibilityValue(row.detail.map(Text.init) ?? Text(""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One line of the option list, whatever is filling it.
///
/// One type for three sources rather than three views: they are the same row
/// with the same selection pill, and three copies is three places for the height
/// to drift.
struct CommandOptionRow: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var symbolName: String?
    var isRequired = false
    /// What picking this row does.
    var action: Action

    enum Action: Hashable, Sendable {
        /// Fill the option being answered with this value.
        case fill(CommandValue)
        /// Move the caret to a different option.
        case focus(String)
    }
}
