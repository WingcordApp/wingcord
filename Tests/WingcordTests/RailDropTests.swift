import CoreGraphics
import Testing
import WingcordCore
@testable import Wingcord

/// Where a carried tile lands, on Discord's zones (`759223`), and what an
/// unnamed folder is called (`n8`).
@Suite("Rail drops")
struct RailDropTests {

    private func g(_ raw: UInt64) -> GuildID { GuildID(rawValue: raw) }

    /// Servers 1 and 2 loose, folder 5 open with 3 and 4 in it, server 6
    /// loose: the tiles as the rail lays them out, 44 points each, 8 between,
    /// the open folder's well padded by 8 above and below its servers.
    private var folders: [GuildFolder] {
        [
            GuildFolder(guildIDs: [g(1)]),
            GuildFolder(guildIDs: [g(2)]),
            GuildFolder(id: 5, guildIDs: [g(3), g(4)]),
            GuildFolder(guildIDs: [g(6)]),
        ]
    }

    private var tiles: [RailDropTile] {
        func frame(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 68, height: 44) }
        return [
            RailDropTile(node: .guild(g(1)), frame: frame(0)),
            RailDropTile(node: .guild(g(2)), frame: frame(52)),
            RailDropTile(node: .folder(5), frame: frame(104)),
            RailDropTile(node: .guild(g(3)), frame: frame(164), folder: 5),
            RailDropTile(node: .guild(g(4)), frame: frame(216), folder: 5, closesFolder: true),
            RailDropTile(node: .guild(g(6)), frame: frame(284)),
        ]
    }

    private func target(_ y: CGFloat, carrying source: RailNodeID) -> RailDropTarget? {
        RailDropTargeting.target(at: y, dragging: source, tiles: tiles, folders: folders, gap: 8)
    }

    @Test("A tile's top three-eighths, and the gap above it, put the entry above it")
    func above() {
        let hit = target(52 + 44 * 0.2, carrying: .guild(g(6)))
        #expect(hit?.drop == .move(.guild(g(6)), nextTo: .guild(g(2)), below: false))
        #expect(hit?.mark == .line(y: 48))
        #expect(target(49, carrying: .guild(g(6)))?.drop == .move(.guild(g(6)), nextTo: .guild(g(2)), below: false))
    }

    @Test("The middle of a top-level tile takes a server into it")
    func combine() {
        #expect(target(52 + 22, carrying: .guild(g(6)))?.drop == .combine(g(6), with: .guild(g(2))))
        #expect(target(52 + 22, carrying: .guild(g(6)))?.mark == .ring(.guild(g(2))))
        // Onto the open folder's own tile: into the folder.
        #expect(target(104 + 22, carrying: .guild(g(1)))?.drop == .combine(g(1), with: .folder(5)))
    }

    @Test("A tile's foot is the next tile's \"above\"")
    func foot() {
        #expect(target(52 + 44 * 0.95, carrying: .guild(g(6)))?.drop == .move(.guild(g(6)), nextTo: .folder(5), below: false))
    }

    @Test("A server inside an open folder takes nothing into it; its foot at the end is the folder's end")
    func insideFolder() {
        #expect(target(164 + 22, carrying: .guild(g(1)))?.drop == .move(.guild(g(1)), nextTo: .guild(g(3)), below: false))
        let end = target(216 + 44 * 0.95, carrying: .guild(g(1)))
        #expect(end?.drop == .combine(g(1), with: .folder(5)))
        // Past the well, the next top-level tile's "above": out of the folder.
        #expect(target(276, carrying: .guild(g(3)))?.drop == .move(.guild(g(3)), nextTo: .guild(g(6)), below: false))
    }

    @Test("A folder goes only between top-level entries, and never into anything")
    func folderSource() {
        #expect(target(164 + 5, carrying: .folder(5)) == nil)
        #expect(target(52 + 22, carrying: .folder(5))?.drop == .move(.folder(5), nextTo: .guild(g(2)), below: false))
    }

    @Test("Nothing lands on itself, and past the last tile is below the last entry")
    func edges() {
        #expect(target(52 + 22, carrying: .guild(g(2))) == nil)
        #expect(target(400, carrying: .guild(g(1)))?.drop == .move(.guild(g(1)), nextTo: .guild(g(6)), below: true))
    }

    @Test("An unnamed folder is its servers' names, as many as fit in sixty-four characters")
    func defaultName() {
        #expect(RailFolder.defaultName(for: ["Alpha", "Beta"]) == "Alpha, Beta")
        let long = String(repeating: "x", count: 40)
        #expect(RailFolder.defaultName(for: [long, long, "Short"]) == "\(long), Short, ...")
        // The first is always taken, however long.
        let huge = String(repeating: "y", count: 80)
        #expect(RailFolder.defaultName(for: [huge, "A"]) == "\(huge), ...")
    }
}
