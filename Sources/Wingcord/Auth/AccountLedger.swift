import Foundation
import Synchronization
import WingcordCore

/// The non-secret half of an account: who it is, so a switcher can show a name
/// and a face without unlocking the Keychain.
///
/// Deliberately separate from the token. A list of accounts is read on every
/// launch to decide what to show; a token is read once, when one is chosen.
nonisolated struct StoredAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var username: String
    var displayName: String?
    var avatarHash: String?
    /// Discord refused its token. It stays listed, because somebody who had five
    /// accounts should see which one needs signing in again, not find one gone.
    var isSessionExpired = false

    init(
        id: String,
        username: String,
        displayName: String? = nil,
        avatarHash: String? = nil,
        isSessionExpired: Bool = false
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarHash = avatarHash
        self.isSessionExpired = isSessionExpired
    }

    /// An entry written before accounts could expire has no such key.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarHash = try container.decodeIfPresent(String.self, forKey: .avatarHash)
        isSessionExpired = try container.decodeIfPresent(Bool.self, forKey: .isSessionExpired) ?? false
    }

    var preferredName: String { displayName ?? username }
    var monogram: String { preferredName.first.map(String.init)?.uppercased() ?? "?" }

    /// The picture, at a size. An account with none of its own gets Discord's default,
    /// by `User.defaultAvatarIndex`'s rule for a migrated account: every stored one is.
    func avatarURL(side: CGFloat) -> URL? {
        guard let raw = UInt64(id) else { return nil }
        guard let avatarHash else { return CDN.defaultAvatar(index: Int((raw >> 22) % 6)) }
        return CDN.avatar(userID: UserID(rawValue: raw), hash: avatarHash, side: side)
    }
}

/// The accounts on this Mac, most recently used first.
///
/// **A value, so its rules can be tested with nothing behind it**: no Keychain and no
/// defaults. `AccountLedger` is what keeps it.
nonisolated struct AccountList: Equatable, Sendable {
    /// Discord's own limit (`MultiAccountStore`, `_.length>5&&_.splice(5)`).
    static let limit = 5

    private(set) var accounts: [StoredAccount]

    init(_ accounts: [StoredAccount] = []) {
        self.accounts = accounts
    }

    var canAdd: Bool { accounts.count < Self.limit }

    /// Who to open on launch.
    ///
    /// **The last one used, or nobody.** One whose session died goes to the picker rather
    /// than quietly opening the next account down: an app that silently picks an account
    /// is one that opens the wrong one.
    var accountToResume: StoredAccount? {
        guard let first = accounts.first, !first.isSessionExpired else { return nil }
        return first
    }

    /// Signed in with a working token, which makes it the newest and clears any expiry.
    ///
    /// - Returns: who fell off the end, whose tokens have to go too.
    mutating func signedIn(_ account: StoredAccount) -> [StoredAccount] {
        accounts.removeAll { $0.id == account.id }
        var fresh = account
        fresh.isSessionExpired = false
        accounts.insert(fresh, at: 0)
        guard accounts.count > Self.limit else { return [] }
        let dropped = Array(accounts[Self.limit...])
        accounts.removeLast(accounts.count - Self.limit)
        return dropped
    }

    /// Added, and not used yet: on the end, or where it was if it's signing in again.
    ///
    /// **Not at the top**, which is what the next launch opens: somebody who adds an account
    /// and says no to switching right now hasn't asked to wake up as it.
    ///
    /// - Returns: who it pushed out, which a full list has to.
    mutating func added(_ account: StoredAccount) -> [StoredAccount] {
        var fresh = account
        fresh.isSessionExpired = false
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = fresh
            return []
        }
        var dropped: [StoredAccount] = []
        if accounts.count >= Self.limit { dropped.append(accounts.removeLast()) }
        accounts.append(fresh)
        return dropped
    }

    /// Switched to: the newest now, and the one the next launch opens.
    mutating func used(_ id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts.insert(accounts.remove(at: index), at: 0)
    }

    /// Who it is now, as READY or an update says. It keeps its place.
    mutating func refresh(_ updated: StoredAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == updated.id }) else { return }
        accounts[index] = updated
    }

    mutating func expire(_ id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].isSessionExpired = true
    }

    mutating func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
    }
}

/// Keeps the list: in the defaults, against what the Keychain really holds.
///
/// **`--demo` never reaches the Keychain.** Its service name is the real app's, and a
/// demo signed by the same certificate could read a real token. So its list lives in
/// memory only, and nothing here touches `TokenStore` for it.
nonisolated enum AccountLedger {
    private static let key = "dev.wingcord.accounts"
    private static let demo = Mutex(AccountList())
    private static var isDemo: Bool { LaunchOptions.current.usesDemoFixtures }

    static func accounts() -> [StoredAccount] { list().accounts }

    private static func list() -> AccountList {
        if isDemo { return demo.withLock { $0 } }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([StoredAccount].self, from: data)
        else { return AccountList() }
        // Only accounts whose token is actually present. A ledger entry without
        // a credential is a row that offers a sign-in that cannot happen.
        let available = Set(TokenStore.storedAccountIDs())
        return AccountList(decoded.filter { available.contains($0.id) })
    }

    private static func save(_ list: AccountList) {
        if isDemo {
            demo.withLock { $0 = list }
            return
        }
        guard let data = try? JSONEncoder().encode(list.accounts) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func change(_ body: (inout AccountList) -> Void) {
        var current = list()
        body(&current)
        save(current)
    }

    static func upsert(_ account: StoredAccount) {
        var dropped: [StoredAccount] = []
        change { dropped = $0.signedIn(account) }
        guard !isDemo else { return }
        for account in dropped { TokenStore.removeToken(forAccount: account.id) }
    }

    static func add(_ account: StoredAccount) {
        var dropped: [StoredAccount] = []
        change { dropped = $0.added(account) }
        guard !isDemo else { return }
        for account in dropped { TokenStore.removeToken(forAccount: account.id) }
    }

    static func used(_ id: String) { change { $0.used(id) } }
    static func refresh(_ account: StoredAccount) { change { $0.refresh(account) } }
    static func expire(_ id: String) { change { $0.expire(id) } }

    /// Forgets an account, and its token with it.
    static func remove(_ accountID: String) {
        change { $0.remove(accountID) }
        guard !isDemo else { return }
        TokenStore.removeToken(forAccount: accountID)
    }

    /// `--demo`'s accounts, which it makes up.
    static func seedDemo(_ accounts: [StoredAccount]) {
        demo.withLock { $0 = AccountList(accounts) }
    }
}
