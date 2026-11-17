import Foundation
import WingcordCore
import WingcordNet

// MARK: - Nitro Emoji Packs (docs/ACTIVITIES-CALLS-PICKER.md, decision 16)

extension SessionController {
    /// The packs and the reader's picks, once per session, when the emoji
    /// picker first opens.
    func loadEmojiPacks() async {
        guard !hasLoadedEmojiPacks, !LaunchOptions.current.usesDemoFixtures else { return }
        hasLoadedEmojiPacks = true
        async let packs = try? rest.emojiPacks()
        async let pinned = try? rest.pinnedEmojiPacks()
        let (allPacks, pins) = await (packs, pinned)
        model.emojiPacks = allPacks ?? []
        model.pinnedEmojiPackIDs = pins ?? []
        Self.trace("emoji packs: \(model.emojiPacks.count) offered, \(model.pinnedEmojiPackIDs.count) added")
        model.expressionRevision &+= 1
    }

    /// Discord's Add to picker / Remove: optimistic, written to the account.
    func toggleEmojiPack(_ id: UInt64) {
        let wasPinned = model.pinnedEmojiPackIDs.contains(id)
        if wasPinned {
            model.pinnedEmojiPackIDs.removeAll { $0 == id }
        } else {
            model.pinnedEmojiPackIDs.append(id)
        }
        model.expressionRevision &+= 1
        let ids = model.pinnedEmojiPackIDs
        let name = model.emojiPacks.first { $0.id == id }?.name ?? "Pack"
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
