import Foundation
import WingcordCore
import WingcordNet

// MARK: - Synced preferences, written back

extension SessionController {

    /// Sends one preference's change. The model has already moved; a refusal
    /// puts it back.
    ///
    /// **The privacy page's bytes are re-read after a split-view write.** Both
    /// splice into `text_and_images`, and the page keeps the copy it last
    /// fetched — a later privacy change spliced into that copy would carry the
    /// old split-view setting back with it.
    func writeSyncedPreference(
        _ change: SyncedPreferencesProto.Change,
        restoring previous: SyncedPreferences
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setSyncedPreference(change)
                if case .opensThreadsInSplitView = change, model.messagingPrivacyRaw != nil {
                    let fetched = try await rest.messagingPrivacy()
                    model.messagingPrivacyRaw = (fetched.textRaw ?? Data(), fetched.privacyRaw ?? Data())
                }
            } catch {
                Self.trace("synced preference write failed: \(Self.describe(error))")
                model.syncedPreferences = previous
            }
        }
    }
}
