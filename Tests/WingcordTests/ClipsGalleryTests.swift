import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Clips on a profile (docs/CLIPS-PRESENCE.md, Phase 7.1): the board's tile,
/// the popout's card, playing them, and what an edit sends.
@MainActor
@Suite("Clips gallery")
struct ClipsGalleryTests {

    private let owner = UserID(rawValue: 900_000_000_000_000_001)
    private let game = ApplicationID(rawValue: 1_425_690_433_018_925_056)

    private func clip(_ id: String, video: Bool = true, title: String? = nil) -> ProfileClip {
        ProfileClip(
            storage: .saved(id: id, fileID: "f-\(id)"),
            gameID: game,
            title: title,
            videoURL: video ? URL(string: "https://cdn.discordapp.com/clips/\(id).mp4") : nil,
            thumbnailURL: URL(string: "https://cdn.discordapp.com/clips/\(id).webp")
        )
    }

    private func model(_ clips: [ProfileClip]) -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 7)
        model.profileWidgets[owner] = [ProfileWidget(id: "g", content: .clipsGallery(clips))]
        model.games[game] = Game(id: game, name: "Battlefield 6", media: GameMedia(icon: .hash("abc")))
        return model
    }

    @Test("The board draws only clips that can play, with their game's name")
    func tile() throws {
        let model = model([clip("1", title: "Triple"), clip("2", video: false), clip("3")])
        let board = try #require(model.boardPresentation(for: owner))
        let tile = try #require(board.tiles.first)
        guard case .clips(let clips) = tile.content else {
            Issue.record("not a clips tile")
            return
        }
        #expect(clips.map(\.id) == ["1", "3"])
        #expect(clips.first?.title == "Triple")
        #expect(clips.first?.gameName == "Battlefield 6")
        #expect(tile.title == "Clips Gallery")
    }

    @Test("A gallery of nothing playable draws no tile and no card")
    func emptyGallery() {
        let model = model([clip("1", video: false)])
        #expect(model.boardPresentation(for: owner) == nil)
        #expect(model.widgetPreviews(for: owner).isEmpty)
    }

    @Test("The popout stacks a Clips Gallery card")
    func preview() throws {
        let model = model([clip("1"), clip("2")])
        let previews = model.widgetPreviews(for: owner)
        guard case .clips(let id, let clips) = try #require(previews.first) else {
            Issue.record("not a clips preview")
            return
        }
        #expect(id == "g")
        #expect(clips.count == 2)
    }

    @Test("Pressing a clip plays them all in the viewer, from the one pressed")
    func play() throws {
        let model = model([clip("1"), clip("2"), clip("3")])
        let clips = try #require(model.boardPresentation(for: owner)?.tiles.first).content
        guard case .clips(let drawn) = clips else { return }
        model.playBoardClips(drawn, from: 1, owner: "Amin")
        let request = try #require(model.mediaViewer)
        #expect(request.items.count == 3)
        #expect(request.index == 1)
        let allVideo = request.items.allSatisfy { $0.isVideo }
        #expect(allVideo)
        #expect(request.items[1].sourceURL.lastPathComponent == "2.mp4")
        #expect(request.items[1].posterURL?.lastPathComponent == "2.webp")
        #expect(request.authorName == "Amin")
    }

    @Test("A clip still on this Mac is uploaded first, never written as it is")
    func localClips() {
        let local = ProfileClip(storage: .local(fileURL: URL(filePath: "/clips/a.mp4")), localClipID: "a")
        let content = ProfileWidget.Content.clipsGallery([clip("1"), local])
        #expect(content.clipsOnThisMac == [URL(filePath: "/clips/a.mp4")])
        let widget = ProfileWidget(id: "g", content: content)
        #expect(widget.typeName == "clips_gallery")
        #expect(ProfileWidget.Content.kind(of: content) == .clipsGallery)
    }
}

private extension ProfileWidget.Content {
    static func kind(of content: Self) -> ProfileWidgetKind? { content.kind }
}
