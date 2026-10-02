import AppKit

/// Holds a quit until the rail's last rearrangement is saved.
///
/// **The one thing the process may not take with it.** A rearranged rail is
/// saved ten seconds after the last change, as Discord's client saves it —
/// see `SessionController+Rail` — so a reader who tidies their servers and
/// quits straight away would otherwise find them back where they were.
/// Nothing else here writes to Discord on a delay, which is why this is the
/// only question the quit waits on; the drafts are written on one too, but to
/// this Mac, so they are written on the spot.
@MainActor
final class WingcordAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once the model exists; SwiftUI makes the delegate first.
    static weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The drafts are written a second after the last keystroke; a quit
        // inside that second writes them now. Local, so it costs no wait.
        Self.model?.drafts.flush()
        guard let session = Self.model?.sessionController, session.hasPendingFolderSave else {
            return .terminateNow
        }
        Task {
            // **Bounded.** A quit that hangs on a network that is not there is
            // worse than a rearrangement lost.
            let save = Task { await session.flushFolderSave() }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(3))
                save.cancel()
            }
            await save.value
            deadline.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
