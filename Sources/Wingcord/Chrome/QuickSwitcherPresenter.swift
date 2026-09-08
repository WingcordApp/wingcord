import SwiftUI
import WingcordCore

/// The one place the quick switcher is presented.
///
/// **A layer in the window, not a `.sheet`**, for the reason the profile card is
/// one: every SwiftUI presentation on macOS paints its own backdrop material
/// behind the whole of its content and `.presentationBackground(.clear)` does
/// not suppress it — measured three ways, see `INVARIANTS.md` §1. A panel that
/// is meant to let the transcript lens through it cannot be one.
///
/// The two things a sheet was worth keeping for are done here instead, and
/// neither needed the machinery:
///
///  - **Outside-click and Escape** are one `Button` filling the window behind
///    the panel, carrying `.keyboardShortcut(.cancelAction)`. No local
///    `NSEvent` monitor, so nothing has to be torn down by hand.
///  - **First responder** is never taken, because no window is created — the
///    field's `@FocusState` is inside this window and works the moment the
///    panel appears.
///
/// It is also strictly cheaper: a sheet allocates a window per open, and ⌘K is
/// pressed dozens of times an hour.
struct QuickSwitcherPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// How far down the window the panel sits.
    ///
    /// **Above the middle, not centred.** The list grows downward as somebody
    /// types, and a panel pinned to the centre pushes its own field upward every
    /// time the answer gets longer — which moves the one thing the reader is
    /// looking at. Anchored near the top it grows into empty space and the field
    /// never moves.
    private static let topInset: CGFloat = 96

    /// How far the window is taken down behind the panel.
    ///
    /// **This number is what lets the panel stay clear glass**, and it is the
    /// whole of the trade. Every other clear-glass flyout in this app is legible
    /// because it is a *presentation*, and a presentation paints its own
    /// backdrop material behind the whole of its content — §1. A layer in the
    /// window has none, which is exactly what made the profile card go opaque
    /// (`ProfileGround`: "the transcript read straight through somebody's
    /// roles"). The scrim is this panel's answer to the same problem, and it
    /// keeps the material where the card had to give it up.
    ///
    /// Walked up, not picked. At 0.45 — the profile card's — a message body and
    /// a blue link were plainly readable across the rows and the footer was
    /// illegible; at 0.62 the heading over a paragraph still competed. 0.78
    /// leaves the window's shapes showing through the glass and its *text* as a
    /// ghost, which is what a lensing material over a dimmed window should look
    /// like. It is also the honest signal: this is the most modal surface in the
    /// app, because it takes the whole keyboard.
    private static let scrim: Double = 0.78

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .top) {
                if model.isQuickSwitchShown {
                    dismissLayer
                    panel
                        .padding(.top, Self.topInset)
                        // Grown from the top, where it came from — spatial
                        // symmetry, and the same anchor it collapses back into.
                        .transition(.materialize(from: .top, blurring: false))
                }
            }
            // Declared by the container that should animate, never by the writer
            // — a `withAnimation` on a store property the whole window observes
            // opens a global transaction and animates every view that happens to
            // re-lay-out while it runs.
            .animation(motion.panel, value: model.isQuickSwitchShown)
        }
    }

    /// Outside-click and Escape, as one control.
    ///
    /// A `Button` rather than a tap gesture on a shape: a button is what
    /// `.keyboardShortcut` attaches to, and it makes the two ways out of the
    /// panel the same object rather than two that can disagree.
    ///
    /// **The scrim is what makes clear glass legible.** §4 sends a flyout over
    /// the transcript to `.clear` because `.regular` would frost the content
    /// into a slab — and clear glass over near-black has nothing to refract. A
    /// dimmed window answers both: this is a modal act, dimming what it
    /// interrupts is what a modal act does, and the dimmed window is the ground
    /// the panel then lenses.
    private var dismissLayer: some View {
        Button { model.closeQuickSwitch() } label: {
            Color.black.opacity(Self.scrim).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(Text("Close the quick switcher"))
        .ignoresSafeArea()
        .transition(.opacity)
    }

    /// **Read in the modifier's own body, not inside a closure.** The sections
    /// are a projection over the store, and a read that happens only inside a
    /// builder SwiftUI calls later is not a dependency this view is invalidated
    /// by — the list would never update as anybody typed.
    private var panel: some View {
        QuickSwitcher(
            text: textBinding,
            sections: model.quickSwitchSections,
            filter: model.quickSwitchFilter,
            isLoadingGames: model.isQuickSwitchLoadingGames,
            pick: { model.openQuickSwitchRow($0) },
            dismiss: { model.closeQuickSwitch() }
        )
    }

    /// **The setter goes through the store's own method**, not at the property:
    /// typing is what starts the games request and what cancels it, and a
    /// binding written straight into `quickSwitch?.text` would move the field
    /// without ever asking Discord anything.
    private var textBinding: Binding<String> {
        Binding(
            get: { model.quickSwitch?.text ?? "" },
            set: { model.setQuickSwitchText($0) }
        )
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsQuickSwitcher() -> some View {
        modifier(QuickSwitcherPresenter())
    }
}
