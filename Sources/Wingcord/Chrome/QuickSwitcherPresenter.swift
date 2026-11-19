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

    /// Where the panel's top sits: **centred in the window**, as he asked
    /// ("centering it on the screen", 2026-11-19) — the tallest the panel gets,
    /// in the middle, so it reads as centred when its list is full and its
    /// field never moves while the list grows and shrinks beneath it (a panel
    /// pinned at its *current* centre would push its own field up with every
    /// keystroke). Never closer to the top than the toolbar.
    static func top(inHeight height: CGFloat) -> CGFloat {
        max(minimumTop, (height - QuickSwitcher.maxHeight) / 2)
    }

    private static let minimumTop: CGFloat = 56

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
    /// `Palette.modalScrim` records how its strength was walked up, on this
    /// panel; a topic's panel shares it.

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    if model.isQuickSwitchShown {
                        dismissLayer
                        panel
                            .padding(.top, Self.top(inHeight: proxy.size.height))
                            // Grown out of the middle, where it sits, and
                            // collapsed back into it.
                            .transition(.materialize(from: .center, blurring: false))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                // Declared by the container that should animate, never by the
                // writer — a `withAnimation` on a store property the whole
                // window observes opens a global transaction and animates every
                // view that happens to re-lay-out while it runs.
                .animation(motion.panel, value: model.isQuickSwitchShown)
            }
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
            Palette.modalScrim.contentShape(.rect)
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
