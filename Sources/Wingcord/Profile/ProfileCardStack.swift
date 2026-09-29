import SwiftUI

/// Discord's stacked cards (module `80330`): the first card drawn whole and,
/// when there are more, the edge of the next showing from under it.
///
/// **The peek is a surface, not the second card.** Discord draws an empty card
/// eight points tall and eight in from each side; what is on it is what the
/// full profile is for, and pressing it goes there. Under the pointer the front
/// card lifts two points and the peek shows two more, which is the stack
/// answering the hand before anything is pressed.
///
/// The popout's activities and its widgets are both one of these.
struct ProfileCardStack<Front: View>: View {
    /// Whether anything is behind the front card.
    var hasMore: Bool
    var ground: ProfileGround
    /// Opens the full profile where the rest are.
    var expand: () -> Void
    @ViewBuilder var front: Front

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var isHoveringPeek = false

    private var isRaised: Bool { hasMore && isHovering }

    var body: some View {
        ZStack(alignment: .bottom) {
            if hasMore { peekCard }
            front
                // Discord's `--shadow-low` on a card with another under it: the
                // one cue at rest that the edge below is a second card.
                .shadow(
                    color: .black.opacity(hasMore ? (ground.wantsDarkInk ? 0.08 : 0.14) : 0),
                    radius: 2,
                    y: 1
                )
                .offset(y: isRaised ? -StackGeometry.lift : 0)
        }
        // The resting peek is part of the stack's size; the extra two points
        // on hover are not, as in Discord's — they are the lift, not the room.
        .padding(.bottom, hasMore ? StackGeometry.peek : 0)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
    }

    /// The edge under the card. Taller than what shows — its top is behind the
    /// front card — so only its foot and its two lower corners are ever seen.
    ///
    /// **Cut to what shows, not left behind the front card.** A card on a
    /// themed profile is translucent, and the peek's top showed through it as a
    /// second card's outline across the front one's foot. The mask keeps the
    /// foot at rest and the lift's extra two points on hover, which is exactly
    /// the part below the front card.
    private var peekCard: some View {
        Button(action: expand) {
            ProfilePanelPlate(ground: ground, isHovering: isHoveringPeek)
                .frame(height: StackGeometry.peek * 3)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .mask(alignment: .bottom) {
            Rectangle().frame(height: StackGeometry.peek + (isRaised ? StackGeometry.lift * 2 : 0))
        }
        .padding(.horizontal, StackGeometry.peekInset)
        .offset(y: StackGeometry.peek + (isRaised ? StackGeometry.lift : 0))
        .onHover { hovering in
            guard isHoveringPeek != hovering else { return }
            isHoveringPeek = hovering
        }
        .animation(motion.hover, value: isHoveringPeek)
        .help("View More")
        .accessibilityLabel(Text("View More"))
    }
}

/// The surface every card on a profile's ground is built on — Discord's
/// `UserProfile.Overlay` (module `946356`): the translucent overlay, the hover
/// wash over it, and the edge a light profile gives it. See
/// `ProfileGround.panelFill`.
struct ProfilePanelPlate: View {
    var ground: ProfileGround
    var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        shape
            .fill(ground.panelFill)
            .overlay {
                if isHovering { shape.fill(Palette.hoverFill) }
            }
            .overlay {
                if let edge = ground.panelEdge { shape.strokeBorder(edge, lineWidth: 1) }
            }
    }
}

/// A card on a profile's ground that is one control: the whole of it opens
/// what it summarises, and it answers the pointer with the overlay's hover.
struct ProfilePanelButton<Label: View>: View {
    var ground: ProfileGround
    var action: () -> Void
    @ViewBuilder var label: Label

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { ProfilePanelPlate(ground: ground, isHovering: isHovering) }
                .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
                .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
    }
}

/// Discord's numbers for the stack. Outside the view because a generic type
/// cannot hold a stored static.
private enum StackGeometry {
    /// How much of the peek shows at rest, and how far the front lifts.
    static let peek: CGFloat = 8
    static let lift: CGFloat = 2
    /// The peek is narrower than the card by this much on each side.
    static let peekInset: CGFloat = 8
}
