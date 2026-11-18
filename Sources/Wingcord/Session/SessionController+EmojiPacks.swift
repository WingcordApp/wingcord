import Foundation
import WingcordCore
import WingcordNet

// MARK: - Nitro Emoji Packs (docs/ACTIVITY-CARDS.md, decision 2)

extension SessionController {
    /// The packs and the reader's picks, when the emoji picker opens or a card
    /// asks about an emoji no server of the reader's owns: once per session
    /// after an answer, again after a failure.
    func loadEmojiPacks() async {
        if LaunchOptions.current.usesDemoFixtures {
            guard model.emojiPacksLoad == .idle else { return }
            model.emojiPacks = DemoEmojiPacks.packs
            model.pinnedEmojiPackIDs = DemoEmojiPacks.pinned
            model.emojiPacksLoad = .loaded
            model.expressionRevision &+= 1
            return
        }
        switch model.emojiPacksLoad {
        case .loading, .loaded, .notEnabled: return
        case .idle, .failed: break
        }
        model.emojiPacksLoad = .loading
        async let packs = fetchEmojiPacks()
        async let pinned = try? rest.pinnedEmojiPacks()
        let (answer, pins) = await (packs, pinned)
        switch answer {
        case .success(let list?):
            model.emojiPacks = list
            model.emojiPacksLoad = .loaded
        case .success(nil):
            model.emojiPacks = []
            model.emojiPacksLoad = .notEnabled
        case .failure(let error):
            Self.trace("emoji packs failed: \(Self.describe(error))")
            model.emojiPacksLoad = .failed
        }
        if let pins { model.pinnedEmojiPackIDs = pins }
        Self.trace(
            "emoji packs: \(model.emojiPacks.count) offered, \(model.pinnedEmojiPackIDs.count) added, "
                + "state \(model.emojiPacksLoad), build \(metadata.baseline.webBuildNumber)"
        )
        model.expressionRevision &+= 1
    }

    private func fetchEmojiPacks() async -> Result<[EmojiPack]?, any Error> {
        do { return .success(try await rest.emojiPacks()) } catch { return .failure(error) }
    }

    /// Discord's Add to picker / Remove: optimistic, written to the account.
    ///
    /// **Discord's own guard on adding**: only an available pack, and the
    /// list it writes drops packs that have since become unavailable
    /// (`934499`'s `Ls`).
    func toggleEmojiPack(_ id: UInt64) {
        let wasPinned = model.pinnedEmojiPackIDs.contains(id)
        if wasPinned {
            model.pinnedEmojiPackIDs.removeAll { $0 == id }
        } else {
            guard model.emojiPacks.first(where: { $0.id == id })?.isAvailable == true else { return }
            if model.emojiPacksLoad == .loaded {
                let available = Set(model.emojiPacks.filter(\.isAvailable).map(\.id))
                model.pinnedEmojiPackIDs.removeAll { !available.contains($0) }
            }
            model.pinnedEmojiPackIDs.append(id)
        }
        model.expressionRevision &+= 1
        let ids = model.pinnedEmojiPackIDs
        let name = model.emojiPacks.first { $0.id == id }?.name ?? "Pack"
        // The demo account has nowhere to write it; the pick stands.
        guard !LaunchOptions.current.usesDemoFixtures else {
            model.reportSuccess(wasPinned ? "\(name) Removed" : "\(name) Added")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setPinnedEmojiPacks(ids)
                model.reportSuccess(wasPinned ? "\(name) Removed" : "\(name) Added")
            } catch {
                // Put it back: the account didn't take it.
                if wasPinned { model.pinnedEmojiPackIDs.append(id) } else { model.pinnedEmojiPackIDs.removeAll { $0 == id } }
                model.expressionRevision &+= 1
                model.reportActionFailure(Self.reason(for: error, verb: "change your emoji packs"))
            }
        }
    }
}
