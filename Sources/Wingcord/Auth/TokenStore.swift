import Foundation
import OSLog
import Security

/// Where the account token lives.
///
/// **The Keychain, and nowhere else.** A Discord token is a bearer credential
/// for a whole account — it authenticates every request without a second factor
/// — so `UserDefaults`, a plist, or a file in Application Support are all wrong:
/// each is world-readable to anything running as the user, survives in backups
/// in the clear, and shows up in a screen share.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is deliberate on both halves:
/// *WhenUnlocked* so the token is unreadable while the Mac is locked, and
/// *ThisDeviceOnly* so it never leaves in an iCloud Keychain sync or a backup
/// restored onto another machine.
nonisolated enum TokenStore {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Auth")
    private static let service = "dev.wingcord.Wingcord.token"

    enum Failure: Error {
        case keychain(OSStatus)
    }

    /// Why a read did not produce a token.
    ///
    /// **Missing and denied are different**, and collapsing them is destructive:
    /// the caller deletes the account on a miss, so a denied read — which is
    /// what an ad-hoc-signed app gets after a rebuild changes its code signature
    /// — would silently throw away a perfectly good credential.
    enum ReadFailure: Error {
        /// There is no item. The account really is gone.
        case missing
        /// The item exists but this build could not read it: the signing
        /// identity changed, the user declined the prompt, or the Mac is locked.
        case denied(OSStatus)
    }

    /// Reads the token for one account.
    ///
    /// **Call this off the main thread.** A Keychain read can put a prompt up —
    /// "Wingcord wants to use your confidential information" — and
    /// `SecItemCopyMatching` does not return until it is answered. On the main
    /// thread that is a frozen window.
    static func token(forAccount accountID: String) throws(ReadFailure) -> String {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw .missing }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            log.error("keychain read failed: \(status, privacy: .public)")
            throw .denied(status)
        }
        return token
    }

    /// Writes a token, replacing any previous one for the same account.
    ///
    /// **A token is validated before it reaches here.** Storing one that never
    /// worked means retrying it on every launch forever, with no way for the app
    /// to tell "the network is down" from "this credential is dead".
    static func store(_ token: String, forAccount accountID: String) throws {
        let data = Data(token.utf8)
        var query = baseQuery(accountID: accountID)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Failure.keychain(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.keychain(addStatus) }
    }

    static func removeToken(forAccount accountID: String) {
        SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
    }

    /// Every account this Mac has a stored token for.
    static func storedAccountIDs() -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        query[kSecReturnData as String] = false

        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }
}

/// The non-secret half of an account: who it is, so a switcher can show a name
/// and a face without unlocking the Keychain.
///
/// Deliberately separate from the token. A list of accounts is read on every
/// launch to decide what to show; a token is read once, when one is chosen.
struct StoredAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var username: String
    var displayName: String?
    var avatarHash: String?

    var preferredName: String { displayName ?? username }
}

nonisolated enum AccountLedger {
    private static let key = "dev.wingcord.accounts"

    static func accounts() -> [StoredAccount] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([StoredAccount].self, from: data)
        else { return [] }
        // Only accounts whose token is actually present. A ledger entry without
        // a credential is a row that offers a sign-in that cannot happen.
        let available = Set(TokenStore.storedAccountIDs())
        return decoded.filter { available.contains($0.id) }
    }

    static func upsert(_ account: StoredAccount) {
        var list = accounts().filter { $0.id != account.id }
        list.insert(account, at: 0)
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func remove(_ accountID: String) {
        let list = accounts().filter { $0.id != accountID }
        TokenStore.removeToken(forAccount: accountID)
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
