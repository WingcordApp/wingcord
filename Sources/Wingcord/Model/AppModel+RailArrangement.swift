import CoreGraphics
import Foundation
import WingcordCore

/// A folder's right-click menu, anchored to its tile.
struct FolderMenuRequest: Identifiable, Hashable, Sendable {
    var folderID: UInt64
    /// The tile's frame, in the window root's space — see `SecondaryClickCatcher`.
    var anchor: CGRect

    var id: UInt64 { folderID }
}

/// What the folder menu draws, resolved when it opens.
struct FolderOptions: Hashable, Sendable {
    var folderID: UInt64
    var name: String?
    var colorValue: UInt32?
    /// Anything unread in any of its servers — what Mark Folder As Read is
    /// offered for, as Discord offers it (`842112`).
    var hasUnread: Bool
    /// Whether any folder at all is open, which is when Close All Folders is
    /// offered.
    var hasOpenFolders: Bool
}

extension AppModel {

    // MARK: Rearranging

    /// A drop on the rail, applied by Discord's rules (`GuildArrangement`) and
    /// saved as its client saves it (`SessionController+Rail`).
    func dropOnRail(_ drop: RailDrop) {
        sessionController.arrangeRail { folders in
            switch drop {
            case .move(let source, let target, let below):
                GuildArrangement.move(source, nextTo: target, below: below, in: &folders)
            case .combine(let source, let target):
                GuildArrangement.combine(source, with: target, in: &folders)
            }
        }
    }

    // MARK: A folder's menu

    func openFolderMenu(_ folderID: UInt64, anchor: CGRect) {
        folderMenu = FolderMenuRequest(folderID: folderID, anchor: anchor)
    }

    func folderOptions(for folderID: UInt64) -> FolderOptions? {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return nil }
        let hasUnread = folder.guildIDs.contains { guildID in
            let badge = guildBadge(for: guildID)
            return badge.unread || badge.mentions > 0
        }
        return FolderOptions(
            folderID: folderID,
            name: folder.name,
            colorValue: folder.colorValue,
            hasUnread: hasUnread,
            hasOpenFolders: !expandedFolderIDs.isEmpty
        )
    }

    /// Every server in a folder marked read — Discord's Mark Folder As Read,
    /// which is Mark As Read for each of them.
    func markFolderRead(_ folderID: UInt64) {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return }
        for guildID in folder.guildIDs { markGuildRead(guildID) }
    }

    /// Discord's Close All Folders. Which folders are open is this window's
    /// own business and is never saved — Discord keeps it on the device too.
    func closeAllFolders() {
        expandedFolderIDs = []
    }

    /// A folder renamed or recoloured — Discord's Folder Settings. **The
    /// default colour is no colour**, which is how Discord saves it (`rk`).
    func saveFolderSettings(_ folderID: UInt64, name: String, colorValue: UInt32?) {
        let color = colorValue == RailFolder.defaultColor ? nil : colorValue
        sessionController.arrangeRail { folders in
            GuildArrangement.setFolder(folderID, name: name, colorValue: color, in: &folders)
        }
    }
}
