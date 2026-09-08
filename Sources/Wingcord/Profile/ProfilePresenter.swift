import SwiftUI
import WingcordCore

/// The one place a profile is presented.
///
/// Attached at the window root and nowhere else. Every row that can open a
/// profile — a member row, a message avatar, a mention — sets
/// `AppModel.profileRequest` and stops there, which is what keeps presentation
/// modifiers off the rows themselves. A `.popover` written inline in a member
/// row is a popover *per row*, evaluated as part of every row's body on every
/// evaluation, including its content closure's captures.
///
/// **The card is a layer in the window, not a `.popover` or a `.sheet`, and
/// that is a correction.** It was both, for good reasons that are still true of
/// everything else the app presents. What broke them is a profile frame: its
/// artwork is authored to hang *past* the card, and a system presentation
/// cannot show that at all. Two separate reasons, either one fatal:
///
///  1. **A presentation is an `NSWindow`, and a window cannot draw outside
///     itself.** Whatever room the card does not ask for does not exist.
///  2. **Asking for the room does not help**, because a popover and a sheet
///     both paint their own backdrop material behind the whole of their
///     content, and `.presentationBackground(.clear)` does not suppress it.
///     Measured three ways — see `INVARIANTS.md`. Reserving a margin for the
///     artwork produced a grey panel around the card instead of roses over the
///     transcript.
///
/// So the four things a popover was being kept for are done here instead, and
/// none of them needed the machinery its doc comment used to warn about:
///
///  - **anchoring** and **staying on screen** — `ProfileCardPlacement`, pure
///    arithmetic over a rect the store already carries in the root's own space.
///  - **outside-click and Escape** — one `Button` filling the window behind the
///    card, carrying `.keyboardShortcut(.cancelAction)`. No local `NSEvent`
///    monitor, so nothing has to be torn down by hand and no closure outlives
///    the card.
///  - **first responder** — never taken, because no window is created.
///
/// It is also strictly cheaper: a popover allocates a window per card, and this
/// allocates nothing, so the card now materialises with the app's own motion
/// rather than the system's generic one.
struct ProfilePresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// The card's own width, shared by the card and by the arithmetic that
    /// places it. Two copies is how a card ends up anchored eight points from
    /// where it is drawn.
    private static let cardWidth: CGFloat = 320
    /// The full profile's ceiling, and the air left around it.
    ///
    /// Wide enough for the 360-point identity panel and two 320-point board
    /// slabs beside it with the column's own margins — which is where the
    /// masonry stops adding columns.
    private static let maximumWidth: CGFloat = 1040
    private static let maximumHeight: CGFloat = 780
    private static let inset: CGFloat = 48

    func body(content: Content) -> some View {
        content.overlay {
            // Reads the root's size for the placement to clamp against. A
            // reader, not a stored measurement: the value is consumed in the
            // same pass that produces it and never written to `@State`, so
            // there is no extra layout pass and nothing that can outlive what
            // it measured.
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if let request = model.profileRequest,
                       let profile = model.profilePresentation(for: request) {
                        dismissLayer(dimmed: request.depth == .full)
                        surface(request, profile, container: proxy.size)
                    }
                }
                // Declared by the container that should animate, never by the
                // writer — a `withAnimation` on a store property the whole
                // window observes opens a global transaction and animates every
                // view that happens to re-lay-out while it runs.
                .animation(motion.panel, value: model.profileRequest)
            }
        }
    }

    /// Outside-click and Escape, as one control.
    ///
    /// A `Button` rather than a tap gesture on a shape: a button is what
    /// `.keyboardShortcut` attaches to, it is what VoiceOver can find and
    /// describe, and it makes the two ways out of this card the same object
    /// rather than two that can disagree.
    private func dismissLayer(dimmed: Bool) -> some View {
        Button { model.profileRequest = nil } label: {
            // **A scrim under the full profile, nothing under the card.** A
            // modal task dims what it interrupts; a card beside a row does not
            // interrupt anything, and dimming the transcript behind it would
            // say it did.
            (dimmed ? Color.black.opacity(0.45) : Color.clear)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cancelAction(unless: model.gameProfileRequest != nil || model.isQuickSwitchShown)
        .accessibilityLabel(Text("Close profile"))
        .transition(.opacity)
    }

    @ViewBuilder
    private func surface(
        _ request: ProfileRequest,
        _ profile: ProfilePresentation,
        container: CGSize
    ) -> some View {
        switch request.depth {
        case .mini:
            miniCard(request, profile, container: container)
        case .full:
            ProfileSheet(
                profile: profile,
                board: model.boardPresentation(for: request.userID),
                activity: model.activityPresentation(for: request.userID),
                // **A ceiling, not a size.** The sheet takes this width and as
                // much of this height as its content actually needs — an
                // account with a bio and nothing else is a short sheet rather
                // than four hundred points of void under a name.
                maximumSize: CGSize(
                    width: min(container.width - Self.inset * 2, Self.maximumWidth),
                    height: min(container.height - Self.inset * 2, Self.maximumHeight)
                ),
                dismiss: { model.profileRequest = nil }
            )
            // **And then given the whole container to sit in.** The layer's
            // stack is top-leading aligned, so a sized child without this is
            // pinned to the window's corner — which is where the stage was
            // sitting, an 1,080-point sheet jammed against the top-left edge.
            .frame(width: container.width, height: container.height)
            .transition(.materialize)
        }
    }

    private func miniCard(
        _ request: ProfileRequest,
        _ profile: ProfilePresentation,
        container: CGSize
    ) -> some View {
        let overhang = profile.frame?.overhang(cardWidth: Self.cardWidth) ?? EdgeInsets()
        let placement = ProfileCardPlacement(
            anchor: request.anchor,
            cardWidth: Self.cardWidth,
            overhang: overhang,
            container: container
        )
        return MiniProfileCard(
            profile: profile,
            openFullProfile: {
                // Set the new depth synchronously. Deferring a presentation by
                // a timer to let the first one go is a race that gets lost: the
                // flag lives on the store while the code setting it runs inside
                // a view being torn down, and a missed window drops the request
                // silently.
                model.expandProfile()
            },
            openLink: { model.openLink($0) },
            gameCollection: model.gameCollection(for: request.userID),
            width: Self.cardWidth
        )
        // **Placed by alignment guides, not by `.position` or by a measured
        // `@State`.** The card's height is its content's — a bio and a role flow
        // that arrive over the network — and a guide is handed that height
        // *during* the layout pass that consumes it. Measuring it into state
        // instead would cost an extra pass, invalidate everything downstream,
        // and leave a number that outlives the card.
        //
        // Both guides subtract the overhang, because what they position is the
        // padded box while what the placement solves for is the card. Anchoring
        // the padded box instead would shove the card sideways by the artwork's
        // width the moment a frame resolved.
        .alignmentGuide(.leading) { _ in
            -(placement.cardX - overhang.leading)
        }
        .alignmentGuide(.top) { dimensions in
            let cardHeight = dimensions.height - overhang.top - overhang.bottom
            return -(placement.cardY(forHeight: cardHeight) - overhang.top)
        }
        // Grown from the corner nearest the row that opened it.
        .transition(.materialize(from: placement.growthAnchor))
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsProfiles() -> some View {
        modifier(ProfilePresenter())
    }
}

extension View {
    /// Escape, but only while this really is the topmost layer.
    ///
    /// **Three controls in this app claimed `.cancelAction` at once**, and one
    /// key cannot mean three things: the profile's scrim, the profile sheet's
    /// own close button, and the game profile's scrim above both of them.
    /// SwiftUI settles a contested shortcut by hierarchy rather than by what is
    /// drawn on top, so Escape over an open game profile closed the profile
    /// *underneath* it and left the page floating over nothing.
    ///
    /// The quick switcher is the fourth, and it covers all three — it is opened
    /// by a key rather than by a click, so it is the one layer that can appear
    /// over any of them without anybody having dismissed anything. Its own field
    /// handles Escape while it has focus, but a key *equivalent* is matched
    /// before a key press reaches the responder chain, so the layers underneath
    /// have to give the shortcut up rather than rely on that.
    ///
    /// A conditional `KeyboardShortcut?` rather than `.disabled`: a disabled
    /// control gives up its shortcut but also stops answering the pointer and
    /// takes its label's contrast with it, which is wrong for a button that is
    /// merely covered rather than unavailable.
    func cancelAction(unless isCovered: Bool) -> some View {
        keyboardShortcut(isCovered ? nil : .cancelAction)
    }
}
