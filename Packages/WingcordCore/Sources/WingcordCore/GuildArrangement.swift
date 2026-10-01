import Foundation

/// One entry the reader can pick up in the rail: a server or a folder.
///
/// Discord gives both one id space in its guilds tree; this keeps them apart,
/// because a folder id is a 32-bit random number and nothing stops it from
/// equalling some small guild id in a test.
public enum RailNodeID: Hashable, Sendable {
    case guild(GuildID)
    case folder(UInt64)
}

/// The rail's order and grouping, and every way the reader can change them.
///
/// **Discord's own rules, transcribed**: its `SortedGuildStore` (module
/// `711014`) over its guilds tree (`263715`). The arrangement is the settings
/// proto's folder list (`GuildFolder`): an entry with an id is a folder — of
/// one server, if that is what it holds — and an entry without one is a server
/// sitting loose at that position. Every operation below reads and writes that
/// list and nothing else, because that list is also what goes back to Discord.
public enum GuildArrangement {

    // MARK: Reading the settings

    /// The rail Discord draws for these settings — `N(folders, guildPositions)`.
    ///
    /// 1. **An empty folder list falls back to `guild_positions`**, and only
    ///    then. Discord writes every server into the folder list once anything
    ///    is rearranged, so `guild_positions` is left over from before that and
    ///    goes stale: a captured account's still named a server it had left and
    ///    missed one it had joined (`rearranging servers.har`).
    /// 2. Otherwise the list is the order. A loose entry is its **first** id
    ///    only; a folder keeps its members.
    /// 3. Servers the account is no longer in are dropped, and a folder that
    ///    loses all of them goes with them.
    /// 4. **Every joined server the list does not mention goes on top**, each
    ///    ahead of the one before it (`addNode(…, root, false)`), so the one
    ///    joined last is first. This is where a new server appears.
    ///
    /// - Parameter joined: the account's servers **in the order they were
    ///   joined or listed**, oldest first — READY's own order. It is also the
    ///   set of servers the account is in; a lurked server must not be in it.
    public static func resolve(
        folders: [GuildFolder],
        guildPositions: [GuildID],
        joined: [GuildID]
    ) -> [GuildFolder] {
        let known = Set(joined)
        var placed = Set<GuildID>()
        placed.reserveCapacity(joined.count)
        var result: [GuildFolder] = []
        result.reserveCapacity(joined.count)

        if folders.isEmpty {
            for guildID in guildPositions where known.contains(guildID) {
                guard placed.insert(guildID).inserted else { continue }
                result.append(GuildFolder(guildIDs: [guildID]))
            }
        } else {
            for entry in folders {
                if entry.id == nil {
                    guard let guildID = entry.guildIDs.first,
                          known.contains(guildID),
                          placed.insert(guildID).inserted
                    else { continue }
                    result.append(GuildFolder(guildIDs: [guildID]))
                } else {
                    var members: [GuildID] = []
                    for guildID in entry.guildIDs where known.contains(guildID) {
                        if placed.insert(guildID).inserted { members.append(guildID) }
                    }
                    guard !members.isEmpty else { continue }
                    var folder = entry
                    folder.guildIDs = members
                    result.append(folder)
                }
            }
        }

        var unlisted: [GuildFolder] = []
        for guildID in joined where placed.insert(guildID).inserted {
            unlisted.append(GuildFolder(guildIDs: [guildID]))
        }
        return unlisted.reversed() + result
    }

    /// Puts a server the account has just joined on top, unless it is already
    /// somewhere — Discord's rebuild on `GUILD_CREATE`, for the one server that
    /// rebuild would move. Returns whether anything changed.
    @discardableResult
    public static func placeJoined(_ guildID: GuildID, in folders: inout [GuildFolder]) -> Bool {
        guard !contains(guildID, in: folders) else { return false }
        folders.insert(GuildFolder(guildIDs: [guildID]), at: 0)
        return true
    }

    /// Takes a server the account has left out of the rail, and a folder with
    /// it when that was its last member.
    @discardableResult
    public static func remove(_ guildID: GuildID, from folders: inout [GuildFolder]) -> Bool {
        guard contains(guildID, in: folders) else { return false }
        for index in folders.indices {
            folders[index].guildIDs.removeAll { $0 == guildID }
        }
        folders.removeAll { $0.guildIDs.isEmpty }
        return true
    }

    public static func contains(_ guildID: GuildID, in folders: [GuildFolder]) -> Bool {
        folders.contains { $0.guildIDs.contains(guildID) }
    }

    /// Every server in rail order, folders opened.
    public static func flattened(_ folders: [GuildFolder]) -> [GuildID] {
        folders.flatMap(\.guildIDs)
    }

    // MARK: What a drop may do

    /// Whether `source` may be put beside `target` — Discord's drop target
    /// `tH`: never beside itself, and **a folder only between top-level
    /// entries**, because a folder cannot go inside a folder.
    public static func canMove(_ source: RailNodeID, nextTo target: RailNodeID, in folders: [GuildFolder]) -> Bool {
        guard source != target, locate(source, in: folders) != nil,
              let place = locate(target, in: folders)
        else { return false }
        if case .folder = source, place.child != nil { return false }
        return true
    }

    /// Whether `source` may be dropped ON `target` — Discord's combine target
    /// `tW`: **a server** onto **a top-level entry** other than itself. A
    /// folder cannot be combined with anything, and a server inside a folder
    /// cannot be the start of another one.
    public static func canCombine(_ source: RailNodeID, with target: RailNodeID, in folders: [GuildFolder]) -> Bool {
        guard case .guild = source, source != target, locate(source, in: folders) != nil,
              let place = locate(target, in: folders), place.child == nil
        else { return false }
        return true
    }

    // MARK: Changing it

    /// Puts `source` beside `target`: above it, or below it with `below` —
    /// Discord's `moveNextTo`. Beside a server inside a folder is inside that
    /// folder; a folder left with nothing in it goes. Returns whether anything
    /// changed.
    @discardableResult
    public static func move(
        _ source: RailNodeID,
        nextTo target: RailNodeID,
        below: Bool,
        in folders: inout [GuildFolder]
    ) -> Bool {
        guard canMove(source, nextTo: target, in: folders) else { return false }
        let before = folders
        guard let lifted = pluck(source, from: &folders),
              let place = locate(target, in: folders)
        else {
            folders = before
            return false
        }
        if let child = place.child {
            guard case .guild(let guildID) = source else {
                folders = before
                return false
            }
            folders[place.entry].guildIDs.insert(guildID, at: child + (below ? 1 : 0))
        } else {
            folders.insert(lifted, at: place.entry + (below ? 1 : 0))
        }
        folders.removeAll { $0.guildIDs.isEmpty }
        return folders != before
    }

    /// Drops the server `source` ON `target` — Discord's combine. Onto a
    /// folder, it joins the end of it; onto a server, **the two become a new
    /// folder where that server was, the one dropped on first**
    /// (`convertToFolder`, then `moveInto(…, below: true)`), with no name and no
    /// colour until somebody gives it one. Returns whether anything changed.
    ///
    /// - Parameter random: where a new folder's id comes from — see
    ///   `newFolderID(avoiding:random:)`.
    @discardableResult
    public static func combine(
        _ source: GuildID,
        with target: RailNodeID,
        in folders: inout [GuildFolder],
        random: () -> UInt64 = { UInt64.random(in: 0..<(1 << 32)) }
    ) -> Bool {
        guard canCombine(.guild(source), with: target, in: folders),
              let place = locate(target, in: folders)
        else { return false }
        let before = folders
        let folderID: UInt64
        switch target {
        case .folder(let id):
            folderID = id
        case .guild:
            folderID = newFolderID(avoiding: folders, random: random)
            folders[place.entry].id = folderID
            folders[place.entry].name = nil
            folders[place.entry].colorValue = nil
        }
        guard pluck(.guild(source), from: &folders) != nil,
              let folder = folders.firstIndex(where: { $0.id == folderID })
        else {
            folders = before
            return false
        }
        folders[folder].guildIDs.append(source)
        folders.removeAll { $0.guildIDs.isEmpty }
        return folders != before
    }

    /// A folder renamed or recoloured — Discord's Folder Settings (`672551`).
    /// **An empty name is no name**, which is how the settings write it: the
    /// field is left out rather than sent empty. Anything else is kept as
    /// typed, as Discord keeps it.
    @discardableResult
    public static func setFolder(
        _ folderID: UInt64,
        name: String?,
        colorValue: UInt32?,
        in folders: inout [GuildFolder]
    ) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return false }
        let before = folders[index]
        folders[index].name = name?.isEmpty == false ? name : nil
        folders[index].colorValue = colorValue
        return folders[index] != before
    }

    /// An id for a new folder — Discord's `Math.floor(2 ** 32 * Math.random())`,
    /// drawn again while it names a folder that exists.
    public static func newFolderID(
        avoiding folders: [GuildFolder],
        random: () -> UInt64 = { UInt64.random(in: 0..<(1 << 32)) }
    ) -> UInt64 {
        let taken = Set(folders.compactMap(\.id))
        var id = random()
        while taken.contains(id) { id = random() }
        return id
    }

    // MARK: Where things are

    /// An entry's index in the list, and for a server inside a folder, its
    /// index among that folder's members.
    private struct Place {
        var entry: Int
        var child: Int?
    }

    private static func locate(_ node: RailNodeID, in folders: [GuildFolder]) -> Place? {
        switch node {
        case .folder(let id):
            return folders.firstIndex { $0.id == id }.map { Place(entry: $0, child: nil) }
        case .guild(let guildID):
            for (index, entry) in folders.enumerated() {
                guard let child = entry.guildIDs.firstIndex(of: guildID) else { continue }
                return Place(entry: index, child: entry.id == nil ? nil : child)
            }
            return nil
        }
    }

    /// Takes `node` out of the list and hands back the entry it would be at the
    /// top level. A folder emptied by it stays until the caller is done, so the
    /// indices the caller is about to look up are not moved under it.
    private static func pluck(_ node: RailNodeID, from folders: inout [GuildFolder]) -> GuildFolder? {
        guard let place = locate(node, in: folders) else { return nil }
        switch node {
        case .folder:
            return folders.remove(at: place.entry)
        case .guild(let guildID):
            if let child = place.child {
                folders[place.entry].guildIDs.remove(at: child)
                return GuildFolder(guildIDs: [guildID])
            }
            folders.remove(at: place.entry)
            return GuildFolder(guildIDs: [guildID])
        }
    }
}
