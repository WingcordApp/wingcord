import SwiftUI
import WingcordCore

// MARK: - What these pages need that the app's own settings never did
//
// `SettingsRows` has the vocabulary for a settings window whose every control is
// a switch, a menu or a slider over a value that is already in memory. These
// pages are different in three ways, and each needs one shape:
//
//   1. **Everything is fetched**, so every page has four states rather than one
//      — loading, failed, empty and content — and eighteen panes hand-rolling
//      that is eighteen chances to draw an empty table where a permission error
//      belongs. `LoadableContent` is the whole of it.
//   2. **Things are written**, so a text field has to know when it is dirty and
//      what to do about it. `EditableTextRow` owns that.
//   3. **Things are lists of objects** — emoji, roles, invites, bans — with a
//      picture, a name, a line of provenance and an action. `ObjectRow` is that
//      row, once, instead of six near-identical ones.

// MARK: - The four states

/// Draws a fetched resource, or says why it cannot.
///
/// **A failure is not an empty list**, and conflating them is the mistake this
/// exists to prevent: an administrator without `BAN_MEMBERS` who is shown an
/// empty Bans page concludes the server has no bans, which is a client stating
/// something untrue. `INVARIANTS.md` §5.5.
struct LoadableContent<Value, Content: View, Empty: View>: View {
    var state: Loadable<Value>
    /// What "nothing here" looks like for this page. A closure rather than a
    /// string, because an empty page is usually where the primary action lives —
    /// "no emoji yet" is drawn beside Upload Emoji, not instead of it.
    @ViewBuilder var empty: Empty
    @ViewBuilder var content: (Value) -> Content
    /// Whether the loaded value counts as empty. Nil where the page has no
    /// meaningful empty state — a settings object always has something in it.
    var isEmpty: ((Value) -> Bool)?

    init(
        _ state: Loadable<Value>,
        isEmpty: ((Value) -> Bool)? = nil,
        @ViewBuilder empty: () -> Empty = { EmptyView() },
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.isEmpty = isEmpty
        self.empty = empty()
        self.content = content
    }

    var body: some View {
        switch state {
        case .idle, .loading:
            LoadingRow()
        case .failed(let message):
            FailureRow(message: message)
        case .loaded(let value):
            if isEmpty?(value) == true {
                empty
            } else {
                content(value)
            }
        }
    }
}

/// The spinner every page shows while its route is in flight.
///
/// Centred in a card-height box rather than a bare `ProgressView`: a spinner
/// pinned to the leading edge under a heading reads as a stuck row, and the
/// height keeps the page from collapsing and re-expanding when the answer lands.
struct LoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .frame(height: 96)
        .accessibilityLabel("Loading")
    }
}

/// Why a page has nothing on it.
struct FailureRow: View {
    var message: String

    var body: some View {
        SettingsCard {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.destructive)
                Text(message)
                    .font(SettingsType.rowLabel)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.cardContentInset)
            .padding(.vertical, Spacing.group)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Nothing here yet.
struct EmptyRow: View {
    var message: String
    var symbolName: String

    var body: some View {
        SettingsCard {
            VStack(spacing: Spacing.snug) {
                Image(systemName: symbolName)
                    .font(.system(size: 22))
                    .foregroundStyle(Ink.tertiary)
                Text(message)
                    .font(SettingsType.rowLabel)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.section)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editing text

/// A label and a text field that knows when it has been changed.
///
/// **Commits on blur and on Return, never on keystroke.** Every one of these
/// writes a whole page's worth of fields to Discord — see the captures — and a
/// field that saved per character would send twelve requests to rename a server
/// and rate-limit the reader out of their own settings.
///
/// The revert control is what makes that honest: a field that is dirty says so
/// and offers a way back, rather than silently holding an edit the reader thinks
/// they made.
struct EditableTextRow: View {
    var title: String
    var help: String?
    var placeholder: String
    @Binding var text: String
    /// What the server currently holds. The comparison that decides "dirty".
    var committed: String
    var commit: () -> Void

    @FocusState private var isFocused: Bool

    private var isDirty: Bool { text != committed }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SettingsControlRow(title, help: help) {
                HStack(spacing: Spacing.tight) {
                    if isDirty {
                        Button("Revert") { text = committed }
                            .buttonStyle(.plain)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.tertiary)
                    }
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(Ink.primary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260)
                        .focused($isFocused)
                        .onSubmit(commit)
                        .onChange(of: isFocused) { _, focused in
                            // Blur commits. A field the reader has tabbed away
                            // from is a field they are done with.
                            if !focused, isDirty { commit() }
                        }
                }
            }
        }
    }
}

/// A multi-line field — a description, a template's blurb.
///
/// Its own card rather than a row, because a paragraph in a 34-point row is a
/// single truncated line and the thing being written is prose.
struct EditableTextBlock: View {
    var placeholder: String
    @Binding var text: String
    var committed: String
    var characterLimit: Int
    var commit: () -> Void

    @FocusState private var isFocused: Bool

    private var isDirty: Bool { text != committed }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.primary)
                .frame(minHeight: 76)
                .padding(Spacing.base)
                .background(SettingsSurface.controlTrough, in: .settingsRect(8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(SettingsType.rowLabel)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, Spacing.base + 4)
                            .padding(.vertical, Spacing.base + 2)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused, isDirty { commit() }
                }

            HStack(spacing: Spacing.base) {
                if isDirty {
                    Button("Revert") { text = committed }
                        .buttonStyle(.plain)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                    Button("Save", action: commit)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                // The count appears only once it matters. A counter under an
                // empty field is a limit stated to somebody who has not started.
                if text.count > characterLimit * 3 / 4 {
                    Text("\(text.count)/\(characterLimit)")
                        .font(.system(.caption).monospacedDigit())
                        .foregroundStyle(text.count > characterLimit ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.tertiary))
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.snug)
    }
}

// MARK: - Menus

/// A label and a menu of choices.
///
/// The "none" entry is a real option rather than an empty selection, because
/// every one of these maps to a nullable field on the wire and "No Inactive
/// Channel" has to be pickable to be unsettable.
struct SettingsPickerRow<Value: Hashable>: View {
    var title: String
    var help: String?
    var options: [Option]
    @Binding var selection: Value
    var isEnabled: Bool = true

    struct Option: Identifiable {
        var id: Value { value }
        var value: Value
        var title: String
        var symbolName: String?

        init(_ value: Value, _ title: String, symbolName: String? = nil) {
            self.value = value
            self.title = title
            self.symbolName = symbolName
        }
    }

    var body: some View {
        SettingsControlRow(title, help: help) {
            Menu {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        if let symbolName = option.symbolName {
                            Label(option.title, systemImage: symbolName)
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.tight) {
                    Text(options.first { $0.value == selection }?.title ?? "Select")
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, 5)
                .background(SettingsSurface.controlTrough, in: .settingsRect(7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isEnabled)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Objects in a list

/// One thing in a table of things — an emoji, a role, an invite, a ban.
///
/// A leading mark, a name, a line of provenance under it and up to two trailing
/// controls. One row for six pages, because six rows that differ only in which
/// picture goes on the left is six places for a hover highlight to be a
/// different colour.
struct ObjectRow<Mark: View, Trailing: View>: View {
    private let mark: Mark
    private let title: String
    private let subtitle: String?
    /// A short fact at the trailing end of the title line — a use count, a
    /// shortcode. Distinct from the subtitle, which is provenance.
    private let badge: String?
    private let trailing: Trailing

    @State private var isHovered = false
    @Environment(\.motion) private var motion

    init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        @ViewBuilder mark: () -> Mark,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.mark = mark()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: SettingsMetrics.navigationIconGap) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.tight) {
                    Text(title)
                        .font(SettingsType.rowTitle)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.system(.caption).monospacedDigit())
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Spacing.base)
            trailing
                // Controls appear on hover, and are always present to the
                // keyboard and to VoiceOver — hiding them outright would put
                // this page's only actions behind a pointer.
                .opacity(isHovered ? 1 : 0.55)
        }
        .padding(.leading, SettingsMetrics.navigationIconLeading)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.navigationRowHeight)
        .background(isHovered ? SettingsSurface.rowHover : .clear)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityElement(children: .contain)
    }
}

/// The small circular control at the trailing end of an object row.
struct RowIconButton: View {
    var symbolName: String
    var label: String
    var role: ButtonRole?
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(role == .destructive ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
                .frame(width: 26, height: 26)
                .background(
                    isHovered ? SettingsSurface.controlTrough : .clear,
                    in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Counting

/// "7 of 8 slots used" — the line every expression page opens with.
///
/// A meter rather than a sentence alone: the number that matters is how many are
/// left, and a bar answers that at a glance where "43 of 50" needs arithmetic.
struct SlotMeter: View {
    var used: Int
    var total: Int
    var noun: String

    private var fraction: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("\(used) of \(total) \(noun) used")
                .font(.system(.subheadline, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.primary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SettingsSurface.controlTrough)
                    Capsule()
                        .fill(fraction >= 1 ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Palette.accent))
                        .frame(width: max(0, proxy.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.snug)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(used) of \(total) \(noun) used")
    }
}

// MARK: - Destructive confirmation

/// Wraps a destructive action in a confirmation.
///
/// **Every delete on these pages is irreversible and none of them is undoable.**
/// A deleted role takes its permissions off everybody who had it; a deleted
/// emoji breaks every message that used it. So the confirmation names the thing
/// rather than asking "are you sure" — the name is what tells somebody they have
/// the wrong row.
struct DestructiveConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    var title: String
    var message: String
    var confirmTitle: String
    var perform: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: $isPresented) {
            Button(confirmTitle, role: .destructive, action: perform)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

extension View {
    func destructiveConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String,
        perform: @escaping () -> Void
    ) -> some View {
        modifier(DestructiveConfirmation(
            isPresented: isPresented,
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            perform: perform
        ))
    }
}
