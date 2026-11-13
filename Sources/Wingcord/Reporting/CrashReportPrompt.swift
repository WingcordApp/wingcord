import SwiftUI

/// The question on the launch after a crash, or after a run that stopped
/// answering and was closed (docs/BUG-REPORTING.md D21). Asked every time —
/// Alex's answer to the plan's open question — and never answered for anyone.
struct CrashReportPrompt: View {
    var ending: PreviousRun.Ending
    var answer: (_ report: Bool) -> Void

    var body: some View {
        ModalAlert(
            hero: .symbol(ending.kind == .hang ? "hourglass" : "exclamationmark.triangle", tint: Palette.feedbackWarning),
            title: ending.kind == .hang ? "Wingcord Stopped Responding" : "Wingcord Quit Unexpectedly",
            message: Text(message),
            actions: [
                .cancel("Not Now") { answer(false) },
                .act("Report…", symbol: "ladybug") { answer(true) },
            ]
        )
    }

    private var message: String {
        let what = ending.kind == .hang
            ? "The last time it was open, it stopped answering and was closed."
            : "The last time it was open, it crashed."
        return what + " A report helps get it fixed: it holds what the app was doing, without names, messages or addresses, and you can read all of it first."
    }
}
