import Testing
import WingcordCore

/// The rail's arrangement, on Discord's rules (`711014`, `263715`).
@Suite("Guild arrangement")
struct GuildArrangementTests {

    private func g(_ raw: UInt64) -> GuildID { GuildID(rawValue: raw) }

    private func loose(_ raw: UInt64) -> GuildFolder { GuildFolder(guildIDs: [g(raw)]) }

    private func folder(_ id: UInt64, _ members: [UInt64], name: String? = nil) -> GuildFolder {
        GuildFolder(id: id, name: name, guildIDs: members.map(g))
    }

    // MARK: Reading the settings

    @Test("The folder list is the order, and guild_positions is ignored while it has anything")
    func folderListIsTheOrder() {
        let resolved = GuildArrangement.resolve(
            folders: [loose(1), folder(7, [2, 3]), loose(4)],
            guildPositions: [4, 3, 2, 1].map(g),
            joined: [g(1), g(2), g(3), g(4)]
        )
        #expect(resolved == [loose(1), folder(7, [2, 3]), loose(4)])
    }

    @Test("An empty folder list falls back to guild_positions")
    func positionsFallback() {
        let resolved = GuildArrangement.resolve(
            folders: [],
            guildPositions: [3, 1, 2].map(g),
            joined: [g(1), g(2), g(3)]
        )
        #expect(resolved == [loose(3), loose(1), loose(2)])
    }

    /// **The report**: a server joined went to the bottom of the rail, where
    /// Discord puts it on top.
    @Test("Servers the list does not mention go on top, the last joined first")
    func unlistedGoOnTop() {
        let resolved = GuildArrangement.resolve(
            folders: [loose(1), loose(2)],
            guildPositions: [],
            joined: [g(1), g(2), g(8), g(9)]
        )
        #expect(resolved == [loose(9), loose(8), loose(1), loose(2)])
    }

    @Test("A folder of one server is a folder; a loose entry is its first server only")
    func oneServerFolders() {
        let resolved = GuildArrangement.resolve(
            folders: [folder(5, [1]), GuildFolder(guildIDs: [g(2), g(3)])],
            guildPositions: [],
            joined: [g(1), g(2), g(3)]
        )
        #expect(resolved == [loose(3), folder(5, [1]), loose(2)])
        #expect(resolved[1].isRealFolder)
        #expect(!resolved[2].isRealFolder)
    }

    @Test("Servers left are dropped, and a folder emptied by that goes with them")
    func leftServersDrop() {
        let resolved = GuildArrangement.resolve(
            folders: [folder(5, [1, 2]), folder(6, [3]), loose(4)],
            guildPositions: [],
            joined: [g(2), g(4)]
        )
        #expect(resolved == [folder(5, [2]), loose(4)])
    }

    @Test("A server joined mid-session goes on top once, and keeps its place after")
    func placeJoined() {
        var folders = [loose(1), folder(5, [2, 3])]
        #expect(GuildArrangement.placeJoined(g(9), in: &folders))
        #expect(folders.first == loose(9))
        #expect(!GuildArrangement.placeJoined(g(3), in: &folders))
        #expect(folders.count == 3)
    }

    @Test("Leaving takes the server out, and its folder when it was the last")
    func remove() {
        var folders = [folder(5, [1]), folder(6, [2, 3])]
        GuildArrangement.remove(g(1), from: &folders)
        GuildArrangement.remove(g(2), from: &folders)
        #expect(folders == [folder(6, [3])])
    }

    // MARK: Moving

    @Test("A loose server moves above or below another")
    func moveLoose() {
        var folders = [loose(1), loose(2), loose(3)]
        #expect(GuildArrangement.move(.guild(g(3)), nextTo: .guild(g(1)), below: false, in: &folders))
        #expect(folders == [loose(3), loose(1), loose(2)])
        #expect(GuildArrangement.move(.guild(g(3)), nextTo: .guild(g(2)), below: true, in: &folders))
        #expect(folders == [loose(1), loose(2), loose(3)])
    }

    @Test("Beside a server in a folder is inside that folder; beside a top-level one is out of it")
    func moveIntoAndOut() {
        var folders = [loose(1), folder(5, [2, 3])]
        #expect(GuildArrangement.move(.guild(g(1)), nextTo: .guild(g(3)), below: false, in: &folders))
        #expect(folders == [folder(5, [2, 1, 3])])
        #expect(GuildArrangement.move(.guild(g(2)), nextTo: .folder(5), below: true, in: &folders))
        #expect(folders == [folder(5, [1, 3]), loose(2)])
    }

    @Test("A folder moves only between top-level entries")
    func folderStaysTopLevel() {
        var folders = [loose(1), folder(5, [2, 3]), folder(6, [4])]
        #expect(!GuildArrangement.canMove(.folder(6), nextTo: .guild(g(2)), in: folders))
        #expect(!GuildArrangement.move(.folder(6), nextTo: .guild(g(2)), below: false, in: &folders))
        #expect(GuildArrangement.move(.folder(6), nextTo: .guild(g(1)), below: false, in: &folders))
        #expect(folders == [folder(6, [4]), loose(1), folder(5, [2, 3])])
    }

    @Test("A folder emptied by a move goes")
    func emptiedFolderGoes() {
        var folders = [folder(5, [1]), loose(2)]
        #expect(GuildArrangement.move(.guild(g(1)), nextTo: .guild(g(2)), below: true, in: &folders))
        #expect(folders == [loose(2), loose(1)])
    }

    @Test("Nothing moves beside itself, and a move to where it already is changes nothing")
    func noOpMoves() {
        var folders = [loose(1), loose(2)]
        #expect(!GuildArrangement.move(.guild(g(1)), nextTo: .guild(g(1)), below: false, in: &folders))
        #expect(!GuildArrangement.move(.guild(g(1)), nextTo: .guild(g(2)), below: false, in: &folders))
        #expect(folders == [loose(1), loose(2)])
    }

    // MARK: Combining

    @Test("A server dropped on a server makes a folder there, the one dropped on first")
    func combineMakesAFolder() {
        var folders = [loose(1), loose(2), loose(3)]
        #expect(GuildArrangement.combine(g(1), with: .guild(g(3)), in: &folders, random: { 77 }))
        #expect(folders == [loose(2), folder(77, [3, 1])])
        #expect(folders[1].name == nil && folders[1].colorValue == nil)
    }

    @Test("A server dropped on a folder joins its end")
    func combineIntoFolder() {
        var folders = [loose(1), folder(5, [2, 3])]
        #expect(GuildArrangement.combine(g(1), with: .folder(5), in: &folders))
        #expect(folders == [folder(5, [2, 3, 1])])
    }

    @Test("Only a server combines, and only onto a top-level entry")
    func combineGates() {
        let folders = [loose(1), folder(5, [2, 3]), folder(6, [4])]
        #expect(!GuildArrangement.canCombine(.folder(6), with: .guild(g(1)), in: folders))
        #expect(!GuildArrangement.canCombine(.guild(g(1)), with: .guild(g(2)), in: folders))
        #expect(!GuildArrangement.canCombine(.guild(g(1)), with: .guild(g(1)), in: folders))
        #expect(GuildArrangement.canCombine(.guild(g(2)), with: .folder(6), in: folders))
    }

    @Test("A new folder's id is drawn again while it names a folder that exists")
    func freshFolderID() {
        var draws: [UInt64] = [5, 5, 9]
        let id = GuildArrangement.newFolderID(avoiding: [folder(5, [1])], random: { draws.removeFirst() })
        #expect(id == 9)
    }

    @Test("Folder settings: an empty name is no name, anything else is kept as typed")
    func folderSettings() {
        var folders = [folder(5, [1], name: "Old")]
        #expect(GuildArrangement.setFolder(5, name: "", colorValue: 0x3498DB, in: &folders))
        #expect(folders[0].name == nil)
        #expect(folders[0].colorValue == 0x3498DB)
        GuildArrangement.setFolder(5, name: " Mods ", colorValue: nil, in: &folders)
        #expect(folders[0].name == " Mods ")
        #expect(folders[0].colorValue == nil)
    }
}
