import SwiftUI

// MARK: - Modals
//
// Wingcord's own sheets, alerts and dialogs — one card in the window, grown out
// of whatever opened it and shrunk back into it (docs/SHEETS-SETTINGS.md D11).
//
// **Why not `.sheet`.** On macOS a sheet is a second window dropped from the
// title bar: it cannot grow out of a control, cannot change shape between two
// steps, and draws the system's buttons whatever is put in it. The 27 SDK still
// marks `NavigationTransition.zoom` unavailable here. So the card is drawn in
// the window itself, by a host each window installs once at its root
// (`hostsModals`), and asked for where `.sheet` used to be asked for:
//
//     .modal(item: $model.channelCreation) { request in CreateChannelSheet(request: request) }
//
// **How a card gets from the asking view to the host: a preference.** Each
// presented site hands its card up the tree as a `ModalEntry`, and the host
// reads every entry at the root. A preference, rather than a registry the host
// observes, because it is re-sent every time the asking view is re-evaluated —
// so a card that reads the asking view's own `@State` (a spinner while it
// saves) stays live — and because it carries out of a `NavigationSplitView`'s
// detail column and a `List` row, which a probe confirmed on macOS 27 before
// this was built.
//
// The rules that come with it are in `INVARIANTS.md` (the modal host).

/// What kind of card a modal is — D11b's three shapes.
enum ModalStyle: Hashable, Sendable {
    /// A question with a hero: a picture or a symbol, a title, a few lines,
    /// two equal capsules. Ignore, Delete Message, Leave Server.
    case alert
    /// A task: a title, a line, fields, Cancel and the act.
    case form
    /// A page or a list: its own header, a round ✕. Events, Reactions.
    case panel
}

/// One presented modal, on its way up to the window's host.
struct ModalEntry: Identifiable {
    /// The asking site's token — stable for as long as that site lives.
    var id: UUID
    /// What the card shows. A new value while presented is a new card's worth
    /// of state (a `.sheet(item:)` given another item starts over).
    var contentID: AnyHashable
    var style: ModalStyle
    /// When it was asked for, so the newest is on top when two are up.
    var sequence: UInt64
    var content: AnyView
    /// Closes it from the asking side: the binding goes false, or nil.
    var close: @MainActor () -> Void
}

/// Every presented card under a view, in tree order.
struct ModalEntriesKey: PreferenceKey {
    static var defaultValue: [ModalEntry] { [] }

    static func reduce(value: inout [ModalEntry], nextValue: () -> [ModalEntry]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Presents a card while `isPresented` is true — Wingcord's `.sheet`.
    ///
    /// - Parameters:
    ///   - style: the card's shape; a form unless said otherwise.
    ///   - onDismiss: run once the card has been asked to go, however it went.
    func modal<Card: View>(
        isPresented: Binding<Bool>,
        style: ModalStyle = .form,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Card
    ) -> some View {
        modifier(ModalPresenter(
            isPresented: isPresented.wrappedValue,
            contentID: AnyHashable(0),
            style: style,
            close: { isPresented.wrappedValue = false },
            onDismiss: onDismiss,
            card: content
        ))
    }

    /// Presents a card for `item` while it is not nil — Wingcord's
    /// `.sheet(item:)`.
    func modal<Item: Identifiable, Card: View>(
        item: Binding<Item?>,
        style: ModalStyle = .form,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Card
    ) -> some View {
        let value = item.wrappedValue
        return modifier(ModalPresenter(
            isPresented: value != nil,
            contentID: value.map { AnyHashable($0.id) } ?? AnyHashable(0),
            style: style,
            close: { item.wrappedValue = nil },
            onDismiss: onDismiss,
            card: { value.map(content) }
        ))
    }
}

/// The asking side of a modal: hands its card up while it is presented.
private struct ModalPresenter<Card: View>: ViewModifier {
    var isPresented: Bool
    var contentID: AnyHashable
    var style: ModalStyle
    var close: @MainActor () -> Void
    var onDismiss: (() -> Void)?
    var card: () -> Card

    @State private var token = UUID()
    /// When this site's current presentation began. A box rather than state:
    /// it is assigned the first time the entry is sent — inside the update
    /// that presented it, where state cannot be written — and nothing draws
    /// from it but the host's ordering.
    @State private var order = ModalOrder()

    func body(content: Content) -> some View {
        content
            .transformPreference(ModalEntriesKey.self) { entries in
                guard isPresented else { return }
                entries.append(ModalEntry(
                    id: token,
                    contentID: contentID,
                    style: style,
                    sequence: order.sequence(),
                    content: AnyView(card()),
                    close: close
                ))
            }
            .onChange(of: isPresented) { wasPresented, presented in
                guard wasPresented, !presented else { return }
                order.reset()
                onDismiss?()
            }
    }
}

/// The order cards were asked for in, across every site in the app.
private final class ModalOrder {
    private static var counter: UInt64 = 0
    private var assigned: UInt64?

    func sequence() -> UInt64 {
        if let assigned { return assigned }
        Self.counter &+= 1
        assigned = Self.counter
        return Self.counter
    }

    func reset() { assigned = nil }
}
