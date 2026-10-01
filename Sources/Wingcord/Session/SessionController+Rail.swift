import Foundation
import WingcordCore
import WingcordNet

/// The rail's arrangement: the reader's own changes, their save, and the
/// changes that arrive from other clients.
///
/// **Saved the way Discord's client saves it** (`817281`'s `um`, the
/// settings store's `markDirty`): the rail changes at once, and the write
/// goes out ten seconds after the last change — its `FREQUENT_USER_ACTION`
/// delay — so a reader tidying a dozen servers sends one write, not a dozen.
/// The answer is the settled state and replaces the guess.
///
/// **Until the write has landed, the local arrangement wins.** A settings
/// update from another client, or the echo of an earlier write, would put
/// back what the reader just moved; both are ignored while a save is pending
/// and the save's own answer is applied instead.
extension SessionController {

    /// Changes the rail's arrangement and schedules its save. `change` answers
    /// whether it changed anything, and nothing is saved when it did not.
    func arrangeRail(_ change: (inout [GuildFolder]) -> Bool) {
        guard change(&model.folders) else { return }
        model.railRevision &+= 1
        railEdits &+= 1
        folderSaveTask?.cancel()
        folderSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.saveFolders()
        }
    }

    /// Sends a pending save now rather than when its delay runs out. What
    /// quitting waits on, so the last change is not lost with the process.
    func flushFolderSave() async {
        guard folderSaveTask != nil else { return }
        folderSaveTask?.cancel()
        await saveFolders()
    }

    /// Drops a pending save. **Only for an account going away**: the REST
    /// client outlives the account, so a write left scheduled would be sent
    /// with the next account's token.
    func cancelFolderSave() {
        folderSaveTask?.cancel()
        folderSaveTask = nil
    }

    /// Whether the rail holds a change that has not been saved yet.
    var hasPendingFolderSave: Bool { folderSaveTask != nil }

    /// The rail's arrangement as the settings now hold it — another client's
    /// write, the echo of one of ours, or a save's answer.
    func applyFolderSettings(_ settings: GuildFolderSettings) {
        guard folderSaveTask == nil else { return }
        let resolved = GuildArrangement.resolve(
            folders: settings.folders,
            guildPositions: settings.guildPositions,
            joined: joinOrder
        )
        model.guildPositions = settings.guildPositions
        guard resolved != model.folders else { return }
        model.folders = resolved
        model.railRevision &+= 1
    }

    private func saveFolders() async {
        let edit = railEdits
        let folders = model.folders
        let positions = model.guildPositions
        let settled: GuildFolderSettings?
        do {
            settled = try await rest.setGuildFolders(folders, guildPositions: positions)
        } catch {
            Self.trace("folders: save failed — \(Self.describe(error))")
            if edit == railEdits { folderSaveTask = nil }
            return
        }
        // A change made while this was out is its own save, already scheduled;
        // this answer is about a state the rail has left.
        guard edit == railEdits else { return }
        folderSaveTask = nil
        if let settled { applyFolderSettings(settled) }
    }

    /// The account's servers in the order `GuildArrangement.resolve` reads
    /// them, oldest first.
    ///
    /// **The rail's own order, reversed**, because the only servers this
    /// order decides anything for are the ones a settings update does not
    /// mention, and those are already on top of the rail — resolve puts each
    /// ahead of the one before, so handing them over bottom-up keeps the order
    /// they have. A server in the store and not yet in the rail is newer than
    /// all of them and goes last; a lurked one is not the account's and is
    /// left out.
    private var joinOrder: [GuildID] {
        let shown = GuildArrangement.flattened(model.folders)
        let placed = Set(shown)
        let lurked = model.guildPreview?.guildID
        let unplaced = model.guilds.keys.filter { !placed.contains($0) && $0 != lurked }
        return shown.reversed() + unplaced.sorted { $0.rawValue < $1.rawValue }
    }
}
