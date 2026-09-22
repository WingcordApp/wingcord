import Foundation
import WingcordCore

// MARK: - The cosmetics a reader has agreed to see

extension AppModel {

    /// One person's decoration, with whatever the reader switched off removed.
    ///
    /// **Every presentation builder asks this instead of reading `.decoration`
    /// directly**, and that is the whole enforcement: no view in the app touches
    /// `UserDecoration`, so filtering here filters the roster, the transcript,
    /// the profile card, the now bar, the DM list and the overlay at once. A
    /// switch wired at each draw site instead would be a dozen places to forget.
    ///
    /// **It costs nothing for the reader who has switched nothing off**, which
    /// is nearly all of them: the set is empty, `suppressing` returns the object
    /// it was given, and this is a dictionary miss and a branch. Only somebody
    /// who has actually asked pays for the filtered copy, and that one is
    /// memoized against the set that produced it.
    func cosmetics(of user: User) -> UserDecoration? {
        guard let decoration = user.decoration else { return nil }
        let suppressed = suppression(for: user.id)
        guard !suppressed.isEmpty else { return decoration }
        // **Keyed on BOTH inputs, and the source is an object identity.**
        // `UserDecoration` is a class and a gateway update replaces it wholesale
        // — so a memo keyed on the person alone would go on serving the filtered
        // copy of a nameplate they had already changed, and one keyed on the
        // preference alone would do the same. Two words compared, no hashing of
        // the decoration itself.
        let source = ObjectIdentifier(decoration)
        if let cached = cosmeticMemo[user.id],
           cached.source == source,
           cached.key == suppressed
        {
            return cached.value
        }
        let filtered = decoration.suppressing(suppressed)
        cosmeticMemo[user.id] = (source, suppressed, filtered)
        return filtered
    }

    /// What applies to this person.
    ///
    /// **The reader's own cosmetics are exempt unless they said otherwise.**
    /// Somebody who turns nameplates off is usually saying "stop other people's
    /// decorations shouting at me", not "take the thing I bought off my own
    /// name" — so `suppressesOwnCosmetics` is a second, deliberate switch.
    private func suppression(for userID: UserID) -> CosmeticSuppression {
        let settings = AppSettings.shared
        guard userID != currentUserID || settings.suppressesOwnCosmetics else {
            return []
        }
        return settings.suppressedCosmetics
    }

}
