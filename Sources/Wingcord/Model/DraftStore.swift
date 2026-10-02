import Foundation
import WingcordCore

/// The reader's unsent words, kept on this Mac across a relaunch.
///
/// **Discord's `DraftStore` (module `31717`)**: one draft per channel per
/// account, stamped on every edit, kept on the device rather than synced — and
/// the source of the quick switcher's Drafts. The words themselves already live
/// on `MessageBox.draft`, which survives a channel switch and an eviction; this
/// is the half that survives quitting.
@MainActor
final class DraftStore {
    struct Draft: Codable, Equatable, Sendable {
        var text: String
        var editedAt: Date
    }

    /// Discord's ceiling on a stored draft: a Nitro message and five hundred
    /// more (`CS1 + 500`).
    static let maximumLength = 4500
    /// How many are kept. Discord drops a draft whose channel it can no longer
    /// find at every connection, which needs every thread the reader could
    /// reach — and this client does not hold them all, so dropping on that test
    /// would throw away the words in an archived thread. It keeps the newest
    /// instead, and drops a draft when its channel is deleted.
    static let capacity = 250
    /// How long after the last keystroke the drafts are written. A write is the
    /// whole table encoded, which a keystroke has no business paying for.
    static let writeDelay: Duration = .seconds(1)

    private(set) var drafts: [ChannelID: Draft] = [:]
    private var accountID: UserID?
    private var pendingWrite: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The account's drafts, read when its session is ready.
    ///
    /// A draft that is only whitespace is not one — Discord drops those as it
    /// loads, and so does this.
    func open(for accountID: UserID) -> [ChannelID: Draft] {
        guard self.accountID != accountID else { return drafts }
        flush()
        self.accountID = accountID
        let stored = defaults.data(forKey: Self.key(for: accountID))
            .flatMap { try? JSONDecoder().decode([String: Draft].self, from: $0) } ?? [:]
        drafts = [:]
        for (id, draft) in stored {
            guard let channelID = ChannelID(id), !Self.isBlank(draft.text) else { continue }
            drafts[channelID] = draft
        }
        return drafts
    }

    /// Records what a composer now holds. An empty one has no draft.
    func note(_ text: String, in channelID: ChannelID, at now: Date = .now) {
        guard accountID != nil else { return }
        if Self.isBlank(text) {
            guard drafts.removeValue(forKey: channelID) != nil else { return }
        } else {
            let capped = text.count > Self.maximumLength ? String(text.prefix(Self.maximumLength)) : text
            guard drafts[channelID]?.text != capped else { return }
            drafts[channelID] = Draft(text: capped, editedAt: now)
            if drafts.count > Self.capacity, let oldest = drafts.min(by: { $0.value.editedAt < $1.value.editedAt }) {
                drafts[oldest.key] = nil
            }
        }
        scheduleWrite()
    }

    /// A channel that is gone takes its draft with it.
    func forget(_ channelID: ChannelID) {
        guard drafts.removeValue(forKey: channelID) != nil else { return }
        scheduleWrite()
    }

    /// The drafts, the most recently edited first — the quick switcher's order.
    var recentlyEdited: [ChannelID] {
        drafts.sorted { $0.value.editedAt > $1.value.editedAt }.map(\.key)
    }

    /// Writes now, if anything is waiting — before a quit, or another account.
    func flush() {
        guard let pendingWrite else { return }
        pendingWrite.cancel()
        self.pendingWrite = nil
        write()
    }

    /// Writes and lets go of the account — the sign-out funnel's.
    func close() {
        flush()
        accountID = nil
        drafts = [:]
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingWrite = nil
            self.write()
        }
    }

    private func write() {
        guard let accountID else { return }
        let table = Dictionary(uniqueKeysWithValues: drafts.map { (String($0.key.rawValue), $0.value) })
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: Self.key(for: accountID))
    }

    private static func key(for accountID: UserID) -> String { "drafts.\(accountID.rawValue)" }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
