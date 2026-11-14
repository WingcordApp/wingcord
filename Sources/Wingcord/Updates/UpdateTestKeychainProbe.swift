import Foundation
import WingcordCore

/// The Keychain read a signed-in launch makes, **in a copy that tests the
/// updater only** (docs/UPDATES.md §8), so the prompt an update brings can be
/// seen and answered: a self-signed build has no team id, so the item's
/// partition list names the build that saved it by its hash, and the next
/// build has to be let in — "wants to use your confidential information",
/// the Mac's password, Always Allow (D1).
///
/// The copy runs the demo and never signs in, so without this it never reads
/// a token. It saves a dummy item under its own Keychain service (never the
/// real app's — `TokenStore` takes the copy's from `WingcordKeychainService`)
/// the first time, then reads it at every launch, off the main thread as
/// `SessionController`'s resume does. What happened goes into the log.
nonisolated enum UpdateTestKeychainProbe {
    static let account = "update-test-probe"

    static func runIfTestCopy() {
        guard Bundle.main.bundleIdentifier == LaunchOptions.updateTestIdentifier else { return }
        Task.detached(priority: .userInitiated) {
            do throws(TokenStore.ReadFailure) {
                _ = try TokenStore.token(forAccount: account)
                Log.info(.app, "updates: keychain probe read its item")
            } catch .missing {
                do {
                    try TokenStore.store("update-test-probe", forAccount: account)
                    Log.info(.app, "updates: keychain probe saved its item")
                } catch {
                    Log.info(.app, "updates: keychain probe couldn't save its item: \(public: String(describing: error))")
                }
            } catch .denied(let status) {
                Log.info(.app, "updates: keychain probe was refused (\(public: String(status)))")
            }
        }
    }
}
