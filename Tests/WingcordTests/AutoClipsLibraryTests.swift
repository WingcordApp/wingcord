import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Auto Clips in the library (docs/CLIPS-PRESENCE.md, Phase 7.2): waiting out
/// of sight, kept into the library with what they know, or thrown away.
@MainActor
@Suite("Auto Clips library", .serialized)
struct AutoClipsLibraryTests {

    /// A clips folder of its own for the test, put back afterwards.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) async rethrows {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wingcord-autoclips-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await withAppSettings(\.clipsFolder) { settings in
            settings.clipsFolder = folder
            try body(folder)
        }
    }

    private func writeAutoClip(named name: String, reason: AutoClipReason) -> URL {
        let review = ClipLibrary.reviewFolder
        try? FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        let file = review.appendingPathComponent(name).appendingPathExtension("mp4")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data(count: 64))
        var manifest = ClipManifest(createdAt: .now, duration: 8, game: ClipGame(applicationID: 1, name: "Hades"))
        manifest.method = .auto
        manifest.autoReason = reason
        ClipLibrary.writeManifest(manifest, for: file)
        return file
    }

    @Test("Auto Clips wait out of the library; kept, they join it with their reason")
    func keep() async throws {
        try await withTemporaryFolder { folder in
            let file = writeAutoClip(named: "Hades 1", reason: AutoClipReason(kind: .laughter, name: "LOL", score: 1.1))
            #expect(ClipLibrary.contents().isEmpty, "not in the library while waiting")
            let store = ClipLibraryStore()
            store.reload()
            #expect(store.review.count == 1)
            #expect(store.review.first?.autoReason?.label == "LOL")

            store.keep([file])
            #expect(store.review.isEmpty)
            let kept = try #require(store.items.first)
            #expect(kept.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(kept.clip.manifest?.isAutoClip == true, "the sidecar came along")
            #expect(kept.autoReason?.name == "LOL")

            var filter = ClipLibraryFilter()
            filter.autoOnly = true
            #expect(filter.matches(kept, isFavourite: false))
        }
    }

    @Test("Thrown away, an Auto Clip is gone — file and sidecar")
    func discard() async throws {
        try await withTemporaryFolder { _ in
            let file = writeAutoClip(named: "Hades 2", reason: AutoClipReason(kind: .gameEvent, name: "Kill", score: 1))
            let store = ClipLibraryStore()
            store.reload()
            store.discard([file])
            #expect(store.review.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: ClipLibrary.manifestURL(for: file).path(percentEncoded: false)))
        }
    }

    @Test("A clip somebody asked for is not an Auto Clip")
    func manualIsNotAuto() {
        let item = ClipLibraryItem(clip: Clip(
            url: URL(filePath: "/clips/a.mp4"), created: .now, byteCount: 1, isScreenshot: false,
            manifest: ClipManifest(createdAt: .now, duration: 30)
        ))
        #expect(item.autoReason == nil)
        var filter = ClipLibraryFilter()
        filter.autoOnly = true
        #expect(!filter.matches(item, isFavourite: false))
    }
}
