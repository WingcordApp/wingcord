import SwiftUI
import WingcordCore

/// The "…" on a board tile, and what it opens.
///
/// **Two items at most, and the first is conditional.** A tile listing five
/// games can only be reported — "View Game Profile" would have to guess which of
/// the five it meant. An application tile is about exactly one game and offers
/// both.
struct BoardTileMenuButton: View {
    @Binding var isOpen: Bool
    var widgetID: String
    var userID: UserID
    /// Nil on a tile that lists games rather than being about one.
    var gameID: ApplicationID?

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    private static let side: CGFloat = 22

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered || isOpen ? InkColor.primary : InkColor.tertiary)
                .frame(width: Self.side, height: Self.side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        .help("More")
        .accessibilityLabel(Text("Widget actions"))
        .modifier(
            BoardTileMenuPopover(
                isPresented: $isOpen,
                widgetID: widgetID,
                userID: userID,
                gameID: gameID
            )
        )
    }
}

/// The flyout itself.
///
/// A nested `.popover`, like the person menu one card over: the tile lives
/// inside a surface that is itself a layer in the window, so it has no rect in
/// the root's space for the root presenter to anchor to.
private struct BoardTileMenuPopover: ViewModifier {
    @Binding var isPresented: Bool
    var widgetID: String
    var userID: UserID
    var gameID: ApplicationID?

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { isPresented },
                set: { if !$0 { isPresented = false } }
            ),
            arrowEdge: .bottom
        ) {
            BoardTileMenu(
                widgetID: widgetID,
                userID: userID,
                gameID: gameID,
                dismiss: { isPresented = false }
            )
            .environment(model)
            .presentationBackground(.clear)
        }
    }
}

/// The rows.
private struct BoardTileMenu: View {
    var widgetID: String
    var userID: UserID
    var gameID: ApplicationID?
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var hovered: String?

    private static let width: CGFloat = 200
    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let gameID {
                row(
                    id: "profile",
                    title: "View Game Profile",
                    symbolName: "gamecontroller",
                    isDestructive: false
                ) {
                    dismiss()
                    model.openGameProfile(gameID)
                }
                divider
            }
            row(
                id: "report",
                title: "Report Widget",
                symbolName: "flag",
                isDestructive: true
            ) {
                dismiss()
                model.reportWidget(widgetID, of: userID)
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        // Clear and tinted, the app's one flyout material. `.regular` here
        // would frost the transcript behind it into grey and stop it reading as
        // a floating sheet — `INVARIANTS.md` §4.
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.glass))
        .animation(motion.fadeQuick, value: hovered)
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
    }

    private func row(
        id: String,
        title: String,
        symbolName: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Image(systemName: symbolName)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(.subheadline))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDestructive ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.primary))
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .background {
                if hovered == id {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            let next = hovering ? id : nil
            guard hovered != next else { return }
            hovered = next
        }
    }
}
