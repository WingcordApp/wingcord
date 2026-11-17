import SwiftUI

/// The running whiteboard's two controls, at the end of its card's head
/// (Alex, 2026-11-17: Leave "somewhere else", and beside it the board in a
/// window of its own): Open in Separate Window — or back into the card — and
/// Leave.
struct WhiteboardHeaderControls: View {
    var board: WhiteboardCardModel

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button(
                board.isPoppedOut ? "Show in Card" : "Open in Separate Window",
                systemImage: board.isPoppedOut ? "arrow.down.right.and.arrow.up.left" : "macwindow.on.rectangle",
                action: toggleWindow
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Ink.secondary)
            .help(board.isPoppedOut ? "Show in Card" : "Open in Separate Window")

            Button(action: leave) {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: Metrics.compactControl)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            // Red glass, as the bar's Leave was — the one emphasised control
            // on the card.
            .emphasisChrome(Palette.destructive)
            .help("Leave the Whiteboard")
            .accessibilityLabel(Text("Leave the Whiteboard"))
        }
    }

    private func toggleWindow() {
        model.toggleWhiteboardWindow()
    }

    private func leave() {
        model.leaveWhiteboard()
    }
}
