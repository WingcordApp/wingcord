import Foundation
import WingcordCore
import WingcordNet

// MARK: - The Messaging Permissions page, fetched and written back

extension SessionController {

    /// Loads the page. Called when it opens, and once.
    ///
    /// **Fetched rather than read from READY.** A splice needs the bytes it is
    /// splicing into, and `text_and_images` is not among the sub-messages this
    /// client keeps from READY — it is large, it is mostly about surfaces
    /// Wingcord does not draw, and holding it for the life of a session to save
    /// one request on a pane most readers never open is the wrong trade.
    func loadMessagingPrivacy() async {
        guard model.messagingPrivacyRaw == nil else { return }
        do {
            let fetched = try await rest.messagingPrivacy()
            model.messagingPrivacy = fetched.privacy
            model.messagingPrivacyRaw = (fetched.textRaw ?? Data(), fetched.privacyRaw ?? Data())
        } catch {
            Self.trace("messaging permissions load failed: \(Self.describe(error))")
        }
    }

    /// Sends one control's change.
    ///
    /// **Optimistic, and put back on a refusal.** The model has already moved —
    /// that is what makes the switch follow the pointer — so a write that fails
    /// has to undo it, or the page shows a permission the account does not have.
    /// On a privacy surface that is the worst direction to fail in.
    ///
    /// **Nothing is written before the page has loaded.** Without the raw bytes
    /// a patch would replace the reader's whole `text_and_images` or `privacy`
    /// message with the single field this client changed.
    func writeMessagingPrivacy(
        _ change: MessagingPrivacyProto.Change,
        restoring previous: MessagingPrivacy
    ) {
        guard let raw = model.messagingPrivacyRaw else {
            model.messagingPrivacy = previous
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let into = change.isTextAndImages ? raw.text : raw.privacy
                try await rest.setMessagingPrivacy(change, preserving: into)
                // Re-read, because the write is a merge and the next one splices
                // into the result of this one. Keeping the pre-write bytes would
                // make the second change to the same message undo the first.
                let fetched = try await rest.messagingPrivacy()
                model.messagingPrivacy = fetched.privacy
                model.messagingPrivacyRaw = (
                    fetched.textRaw ?? Data(), fetched.privacyRaw ?? Data()
                )
            } catch {
                Self.trace("messaging permissions write failed: \(Self.describe(error))")
                model.messagingPrivacy = previous
            }
        }
    }
}
