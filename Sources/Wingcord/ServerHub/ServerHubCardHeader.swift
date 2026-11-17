import SwiftUI

/// A card's head: its glyph, its title and what rides beside it, and at its
/// trailing end either its own control (the leaderboard's Expand) or, while
/// editing, the card's edit controls.
struct ServerHubCardHeader: View {
    var widget: ServerHubPresentation.Widget
    var isEditing: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Spacing.base) {
            if isEditing {
                // The grip says the card can be picked up; the whole card is
                // what drags.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if let symbol = widget.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
            }
            if !widget.title.isEmpty {
                Text(widget.title)
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
            }
            if let accessory = widget.accessory {
                ServerHubBadge(
                    text: accessory,
                    help: widget.accessoryHelp ?? accessory,
                    isMuted: widget.accessoryIsMuted
                )
            }
            Spacer(minLength: Spacing.base)
            if isEditing {
                ServerHubCardEditControls(widget: widget)
                    .transition(.materialize(from: .trailing))
            } else if case .whiteboard(let board) = widget.content, board.isRunning {
                WhiteboardHeaderControls(board: board)
                    .transition(.materialize(from: .trailing))
            } else if let expansion = widget.expansion {
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") {
                    model.expandServerHubWidget(expansion)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Ink.secondary)
                .help("Expand")
            }
        }
        .padding(.horizontal, Spacing.margin)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Ink.quaternary)
                .frame(height: 1)
        }
    }
}
