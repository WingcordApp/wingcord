import SwiftUI

// MARK: - What a card's contents can ask of it

/// Closes the card the view is in.
///
/// **The close is held in a box, not in this value.** A closure in an
/// environment value cannot be compared, so every view in a card that reads
/// its dismiss was run again each time the card's stage was — on every point
/// of a drag, while it is being thrown. The box is the same reference from one
/// pass to the next, so the value compares equal and nobody is told.
struct ModalDismissAction {
    let box: ModalCloseBox

    @MainActor func callAsFunction() { box.close() }
}

/// What a card's dismiss runs: its stage keeps this current.
final class ModalCloseBox {
    var close: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// The card's own close — nil outside a card.
    @Entry var modalDismiss: ModalDismissAction? = nil
    /// Whether this card is the one on top. A card under another gives up its
    /// keyboard shortcuts, or Escape would close both — `EscapeLayer`'s rule.
    @Entry var isTopModal = true
    /// How far the card has grown out of its origin, 0…1 — what its contents
    /// fade in on.
    @Entry var modalMorphProgress: Double = 1
}

/// `dismiss` for a view that may be in a card or in a system presentation —
/// the card's close where there is one, the system's otherwise.
///
/// **What `@Environment(\.dismiss)` becomes in every view a card shows.** The
/// system's action cannot be made, so a card cannot answer it; a view kept on
/// it would press Cancel and nothing would happen.
@propertyWrapper
struct ModalDismiss: DynamicProperty {
    @Environment(\.modalDismiss) private var modal
    @Environment(\.dismiss) private var system

    var wrappedValue: () -> Void {
        let modal = modal
        let system = system
        return {
            if let modal { modal() } else { system() }
        }
    }

    init() {}
}

/// Whether the card may be thrown away or closed by a click beside it.
struct ModalDismissDisabledKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Keeps the card from being thrown away or closed by a click beside it —
    /// `interactiveDismissDisabled`, for a card. Its own buttons still work.
    func modalDismissDisabled(_ isDisabled: Bool = true) -> some View {
        preference(key: ModalDismissDisabledKey.self, value: isDisabled)
    }
}

// MARK: - Buttons

/// A card's buttons: Liquid Glass capsules, a symbol and a word (D11b).
///
/// **The act takes the theme's accent — blue by default** (Alex, 2026-10-26),
/// and **red is kept for a destructive result nobody chose**: Discard
/// Changes. Deleting a channel the reader asked to delete is the act, in the
/// act's colour — the HIG's rule, that the destructive style marks a
/// destruction people did not deliberately choose. An act that cannot be
/// undone takes no Return, so it is read before it is pressed.
struct ModalButton: View {
    enum Role {
        /// The way out: plain glass, Escape.
        case cancel
        /// The act: the accent's glass, Return unless it cannot be undone.
        case act
        /// A destructive result nobody chose: red glass, no Return.
        case destructive
        /// Another way forward that is not the act: plain glass.
        case secondary
    }

    var title: String
    var symbolName: String?
    var role: Role = .act
    /// The act cannot be undone, so it takes no Return.
    var isIrreversible = false
    /// A write in flight: a spinner where the symbol was, and nothing presses twice.
    var isWorking = false
    /// Stretches to share the row equally — an alert's two capsules.
    var fills = false
    /// A key other than the role's own — ⌘Return on a form with a text area.
    var shortcut: KeyboardShortcut?? = .none
    var action: () -> Void

    @Environment(\.isTopModal) private var isTop

    var body: some View {
        styled
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(isTop ? resolvedShortcut : nil)
            .disabled(isWorking)
    }

    @ViewBuilder
    private var styled: some View {
        switch role {
        case .cancel, .secondary:
            Button(action: action) { label }
                .buttonStyle(.glass)
        case .act:
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
        case .destructive:
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .tint(Palette.destructive)
        }
    }

    private var label: some View {
        HStack(spacing: Spacing.base) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            } else if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(.body, weight: .semibold))
                    .transition(.opacity)
            }
            Text(title)
                .font(.system(.body, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.tight)
        .frame(maxWidth: fills ? .infinity : nil, minHeight: 28)
    }

    private var resolvedShortcut: KeyboardShortcut? {
        if case .some(let chosen) = shortcut { return chosen }
        return switch role {
        case .cancel: .cancelAction
        case .act: isIrreversible ? nil : .defaultAction
        case .destructive, .secondary: nil
        }
    }
}

/// The round glass ✕ a panel closes with — Escape too, while it is on top.
struct ModalCloseButton: View {
    var label = "Close"
    /// False where the layer it sits in answers Escape itself — the events
    /// panel's scrim does, and two buttons on one key is no key at all.
    var answersEscape = true
    var action: () -> Void

    @Environment(\.isTopModal) private var isTop

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(.body, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .keyboardShortcut(isTop && answersEscape ? .cancelAction : nil)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - A card's heading and fields

/// A card's heading, where the card is not a `FormSheet`: the title in the
/// card's type, a line under it, and the round Liquid Glass ✕ — the HIG's
/// "Close dismisses a modal", its standard symbol with no label.
struct ModalHeader<Accessory: View>: View {
    var title: String
    var subtitle: Text?
    /// Nil where the card closes only through its own buttons.
    var close: (() -> Void)?
    @ViewBuilder var accessory: Accessory

    init(
        title: String,
        subtitle: Text? = nil,
        close: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.close = close
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(verbatim: title)
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    subtitle
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .tint(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
            if let close {
                ModalCloseButton(action: close)
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }
}

extension View {
    /// The ground a card's text field sits on: a raised fill and a hairline,
    /// lit with the accent while it has the keyboard. The field inside is the
    /// system's (`.textFieldStyle(.plain)`); this is only its well.
    func modalFieldGround(isFocused: Bool = false, in shape: some InsettableShape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)) -> some View {
        background(Palette.surfaceRaised, in: shape)
            .overlay {
                shape.strokeBorder(isFocused ? Palette.accent : Palette.edge, lineWidth: isFocused ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - Steps

extension AnyTransition {
    /// A step of a card turning in place (D11c): the new page slides in 24
    /// points from the reading direction it was reached in and fades up, the
    /// old one leaves the other way. The card's ground follows its contents'
    /// size, so the card itself resizes rather than being replaced.
    ///
    /// Put the page in a `ZStack` keyed by `.id(step)`, so the two pages
    /// overlap while they cross instead of stacking.
    static func modalStep(forward: Bool) -> AnyTransition {
        let travel: CGFloat = forward ? 24 : -24
        return .asymmetric(
            insertion: .offset(x: travel).combined(with: .opacity),
            removal: .offset(x: -travel).combined(with: .opacity)
        )
    }
}

/// A card's one-line field: the system's text field on the card's field
/// ground, a symbol where one says what goes in it.
struct ModalTextField: View {
    var placeholder: String
    @Binding var text: String
    var symbolName: String?
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($isFocused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Metrics.composerControlHeight)
        .modalFieldGround(isFocused: isFocused)
    }
}

extension View {
    /// A text field on the card's field ground — what `.roundedBorder`, the
    /// box from before Liquid Glass, was in these forms (Alex, 2026-10-14:
    /// never a rounded-border text field). The field stays the system's; this
    /// is only its well.
    func modalField() -> some View {
        textFieldStyle(.plain)
            .font(.system(.body))
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .frame(minHeight: Metrics.composerControlHeight)
            .modalFieldGround()
    }
}
