import SwiftUI

/// The whiteboard: live in the card while it runs, otherwise its canvas and
/// the one button that starts it.
///
/// **Live where it is**, as Discord's widget is: the activity stage is drawn
/// inside the card for the hub's own channel (`ActivityStageContainer`), so
/// drawing happens on the page, not somewhere the reader has to go.
struct WhiteboardCardView: View {
    var board: WhiteboardCardModel

    @Environment(AppModel.self) private var model

    var body: some View {
        if board.isRunning, let channelID = board.channelID, !board.isEditing {
            ActivityStageContainer(channelID: channelID) { _ in }
                .padding(.top, Spacing.base)
        } else {
            ZStack {
                WhiteboardCanvasPattern()
                VStack(spacing: Spacing.snug) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .symbolEffect(.bounce, value: board.isLaunching)
                    if board.drawingCount > 0, !board.isEditing {
                        WhiteboardDrawingNow(faces: board.drawing, count: board.drawingCount)
                    }
                    switch board.access {
                    case .allowed where !board.isEditing:
                        Button(action: launch) {
                            HStack(spacing: Spacing.base) {
                                if board.isLaunching {
                                    ProgressView().controlSize(.small)
                                }
                                Text(board.isLaunching ? "Starting\u{2026}" : "Launch Whiteboard")
                                    .font(.system(.body, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.group)
                            .frame(height: 40)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        // The canvas's one action: tinted, the accent in the glass.
                        .emphasisChrome(Palette.accent, in: .capsule)
                        .disabled(board.isLaunching)
                    case .allowed:
                        Text("Leave editing to draw on the whiteboard.")
                            .font(.system(.callout))
                            .foregroundStyle(Ink.secondary)
                    case .denied:
                        Text("You don\u{2019}t have access.")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(Ink.secondary)
                    case .unavailable:
                        Text("The whiteboard isn\u{2019}t set up for this server yet.")
                            .font(.system(.callout))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(Spacing.group)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            // Discord's widget opens the board by itself for a reader who has
            // authorized the app before (`useEffect` → `im(n)`): joining the
            // one running here, or starting one.
            .task(id: board.channelID) {
                model.sessionController.loadAuthorizedApps()
            }
            .onChange(of: board.opensByItself, initial: true) { _, opens in
                guard opens, board.access == .allowed, !board.isEditing, !board.isRunning,
                      !board.isLaunching
                else { return }
                launch()
            }
        }
    }

    private func launch() {
        model.launchWhiteboard()
    }
}
