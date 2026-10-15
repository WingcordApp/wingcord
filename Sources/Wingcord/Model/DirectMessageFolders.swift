import AppKit
import Foundation
import Observation
import WingcordCore

/// The reader's folders of conversations (REDESIGN.md R9): named groups of
/// direct messages that open and close like a server's categories.
///
/// **Local to this Mac, and kept per account.** Discord has no such thing — its
/// folders are for servers — so nothing here travels to the account; switching
/// accounts on this Mac switches folders with it.
@Observable
@MainActor
final class DirectMessageFolders {
    static let shared = DirectMessageFolders()

    struct Folder: Codable, Hashable, Identifiable, Sendable {
        var id: UInt64
        var name: String
        /// The conversations in it. Their order on screen is the list's own —
        /// recency — not this array's.
        var channelIDs: [UInt64]
        var isCollapsed = false
    }

    /// A New Folder… or Rename… waiting on a name, presented by the shell.
    struct NameRequest: Identifiable, Hashable {
        enum Purpose: Hashable {
            /// A new folder, holding `channelID` if one was being filed.
            case create(channelID: ChannelID?)
            case rename(folderID: UInt64)
        }
        let id = UUID()
        var purpose: Purpose
        var initialName: String
    }

    /// Every folder of every account seen on this Mac, by account id.
    private var byAccount: [UInt64: [Folder]]
    /// The account the folders are for, set by the model.
    private(set) var accountID: UInt64?
    /// Moves on every change — the DM list's memo keys on it.
    private(set) var revision: UInt64 = 0
    var nameRequest: NameRequest?

    private let defaults: UserDefaults
    private static let key = "directMessages.folders"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        byAccount = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([UInt64: [Folder]].self, from: $0) } ?? [:]
    }

    // MARK: Reading

    /// The signed-in account's folders, in the reader's order.
    var folders: [Folder] {
        accountID.flatMap { byAccount[$0] } ?? []
    }

    func folder(containing channelID: ChannelID) -> Folder? {
        folders.first { $0.channelIDs.contains(channelID.rawValue) }
    }

    // MARK: The list's category ids

    /// A folder's header in the conversation list is a category row, keyed by
    /// a channel id no snowflake can be: the folder's id under a tag bit
    /// Discord's ids never set.
    static func categoryID(for folderID: UInt64) -> ChannelID {
        ChannelID(rawValue: tag | (folderID & ~tag))
    }

    /// The folder a category id stands for, if it is one of these.
    static func folderID(from categoryID: ChannelID) -> UInt64? {
        categoryID.rawValue & tag == tag ? categoryID.rawValue & ~tag : nil
    }

    /// The header over the conversations in no folder, once there are folders.
    static let unfiledCategoryID = ChannelID(rawValue: tag)

    private static let tag: UInt64 = 1 << 62

    // MARK: Writing

    func setAccount(_ accountID: UInt64?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        revision &+= 1
    }

    /// Starts a New Folder…, holding `channelID` if a conversation is being
    /// filed into it.
    func requestNewFolder(with channelID: ChannelID? = nil) {
        nameRequest = NameRequest(purpose: .create(channelID: channelID), initialName: "")
    }

    func requestRename(_ folderID: UInt64) {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return }
        nameRequest = NameRequest(purpose: .rename(folderID: folderID), initialName: folder.name)
    }

    /// Answers a name request.
    func complete(_ request: NameRequest, name: String) {
        nameRequest = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch request.purpose {
        case .create(let channelID):
            let folder = Folder(id: UInt64.random(in: 1...(1 << 48)), name: name, channelIDs: [])
            update { $0.append(folder) }
            if let channelID { move(channelID, to: folder.id) }
        case .rename(let folderID):
            update { folders in
                if let index = folders.firstIndex(where: { $0.id == folderID }) { folders[index].name = name }
            }
        }
    }

    func delete(_ folderID: UInt64) {
        update { $0.removeAll { $0.id == folderID } }
    }

    /// Files a conversation in a folder — or, with nil, takes it out of the
    /// one it is in. A conversation is in one folder at most.
    func move(_ channelID: ChannelID, to folderID: UInt64?) {
        update { folders in
            for index in folders.indices {
                folders[index].channelIDs.removeAll { $0 == channelID.rawValue }
            }
            if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
                folders[index].channelIDs.append(channelID.rawValue)
            }
        }
    }

    func toggle(_ folderID: UInt64) {
        update { folders in
            if let index = folders.firstIndex(where: { $0.id == folderID }) {
                folders[index].isCollapsed.toggle()
            }
        }
    }

    /// Moves a folder up or down the list.
    func moveFolder(_ folderID: UInt64, by offset: Int) {
        update { folders in
            guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
            let target = min(max(index + offset, 0), folders.count - 1)
            guard target != index else { return }
            let folder = folders.remove(at: index)
            folders.insert(folder, at: target)
        }
    }

    private func update(_ change: (inout [Folder]) -> Void) {
        guard let accountID else { return }
        var folders = byAccount[accountID] ?? []
        change(&folders)
        byAccount[accountID] = folders
        revision &+= 1
        if let data = try? JSONEncoder().encode(byAccount) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

// MARK: - A folder's own menu

/// A folder header's secondary click: rename, reorder, delete. An AppKit menu
/// at the pointer — four plain commands, nothing to lay out.
@MainActor
enum DirectMessageFolderMenu {
    static func show(for folderID: UInt64) {
        let store = DirectMessageFolders.shared
        guard let index = store.folders.firstIndex(where: { $0.id == folderID }) else { return }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Rename Folder…") { store.requestRename(folderID) })
        if index > 0 {
            menu.addItem(ActionMenuItem("Move Up") { store.moveFolder(folderID, by: -1) })
        }
        if index < store.folders.count - 1 {
            menu.addItem(ActionMenuItem("Move Down") { store.moveFolder(folderID, by: 1) })
        }
        menu.addItem(.separator())
        // The conversations stay; only the folder goes.
        menu.addItem(ActionMenuItem("Delete Folder") { store.delete(folderID) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item that runs a closure.
///
/// `nonisolated` because `NSMenuItem`'s initialisers are; its action arrives
/// on the main thread, where a menu is tracked.
private nonisolated final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
