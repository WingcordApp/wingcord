import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
import WingcordVoice
@testable import Wingcord

/// Editor v2's app side (docs/CLIPS-PRESENCE.md, Phase 5): what an item and
/// its edits hand the renderer.
@MainActor
@Suite("Clip editor v2")
struct ClipEditorV2Tests {

    private func item(manifest: ClipManifest?) -> ClipLibraryItem {
        ClipLibraryItem(clip: Clip(
            url: URL(filePath: "/clips/a.mp4"), created: .now, byteCount: 1, isScreenshot: false, manifest: manifest
        ))
    }

    @Test("Captions are drawn only while shown; each keeps its moment on the source's clock")
    func captions() {
        var edits = ClipEdits()
        edits.captions = [Caption(start: 1, end: 2.5, text: "no way"), Caption(start: 3, end: 4, text: "this worked")]
        let shown = ClipRenderInputs.overlays(for: item(manifest: nil), edits: edits, canvasAspect: 16.0 / 9.0)
        #expect(shown.count == 2)
        #expect(shown.map(\.start) == [1, 3])
        #expect(shown.allSatisfy { $0.frame.maxY <= 1 && $0.frame.midY > 0.8 }, "at the canvas's foot")

        edits.captionStyle.placement = .top
        let top = ClipRenderInputs.overlays(for: item(manifest: nil), edits: edits, canvasAspect: 16.0 / 9.0)
        #expect(top.allSatisfy { $0.frame.midY < 0.2 })

        edits.showsCaptions = false
        #expect(ClipRenderInputs.overlays(for: item(manifest: nil), edits: edits, canvasAspect: 16.0 / 9.0).isEmpty)
    }

    @Test("Burnt-in faces: one slot per speaker, shown for each stretch they speak")
    func speakingFaces() {
        let manifest = ClipManifest(
            createdAt: .now, duration: 10,
            participants: [ClipParticipant(userID: 1, name: "Ada"), ClipParticipant(userID: 2, name: "Kim"), ClipParticipant(userID: 3, name: "Kai")],
            timeline: [
                ClipTimelineEvent(timestampMS: 0, event: .speaking(userID: 1, flags: 1)),
                ClipTimelineEvent(timestampMS: 2_000, event: .speaking(userID: 1, flags: 0)),
                ClipTimelineEvent(timestampMS: 3_000, event: .speaking(userID: 2, flags: 1)),
                ClipTimelineEvent(timestampMS: 5_000, event: .speaking(userID: 1, flags: 1)),
            ]
        )
        var edits = ClipEdits()
        #expect(ClipRenderInputs.overlays(for: item(manifest: manifest), edits: edits, canvasAspect: 16.0 / 9.0).isEmpty)
        edits.burnsInSpeaking = true
        let faces = ClipRenderInputs.overlays(for: item(manifest: manifest), edits: edits, canvasAspect: 16.0 / 9.0)
        let spans = faces.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        #expect(spans.count == 3, "Ada twice, Sam once, Kai never")
        #expect(spans[0] == (0, 2) && spans[1] == (3, 10) && spans[2] == (5, 10))
        #expect(Set(faces.map(\.frame.minX)).count == 2, "two slots")
    }

    @Test("The clip's mix while nothing is switched off or cleaned; its stems otherwise")
    func audioTracks() {
        let manifest = ClipManifest(createdAt: .now, duration: 10, tracks: [
            ClipAudioTrack(role: .mix, title: "Mix", isEnabled: true),
            ClipAudioTrack(role: .game, title: "Game", isEnabled: false),
            ClipAudioTrack(role: .voice(userID: 2), title: "Kim", isEnabled: false),
        ])
        let clip = item(manifest: manifest)
        #expect(ClipRenderInputs.audioTracks(of: clip, edits: ClipEdits(), count: 3) == [0])
        #expect(ClipRenderInputs.audioTracks(of: clip, edits: ClipEdits(mutedTracks: [1]), count: 3) == [2])
        #expect(ClipRenderInputs.audioTracks(of: clip, edits: ClipEdits(cleanedStems: [2]), count: 3) == [1, 2],
                "a cleaned voice can't be heard through the mix")
        #expect(ClipRenderInputs.audioTracks(of: item(manifest: nil), edits: ClipEdits(), count: 2) == nil)
    }

    @Test("The system's cursors, drawn at twice their points, hot spot kept")
    func cursorSprites() throws {
        // A test process without a window server has no cursor pictures.
        guard NSCursor.arrow.image.size.width > 0, let arrow = CursorSprites.all[.arrow] else { return }
        #expect(arrow.pointSize.width > 4 && arrow.image.width == Int((arrow.pointSize.width * 2).rounded(.up)))
        #expect(arrow.hotspot.x >= 0 && arrow.hotspot.x <= CGFloat(arrow.image.width))
        #expect(CursorSprites.all[.iBeam] != nil)
    }

    @Test("A shared clip's timeline follows its cuts and speeds")
    func uploadTimeline() throws {
        var edits = ClipEdits()
        edits.setSegments([ClipSegment(start: 0, end: 2), ClipSegment(start: 6, end: 10, speed: 2)])
        var manifest = ClipManifest(createdAt: .now, duration: 10, timeline: [
            ClipTimelineEvent(timestampMS: 1_000, event: .game(type: .kill, name: "Kill")),
            ClipTimelineEvent(timestampMS: 4_000, event: .game(type: .death, name: "Death")),
            ClipTimelineEvent(timestampMS: 8_000, event: .game(type: .multikill, name: "Triple Kill")),
        ])
        manifest.edits = edits
        let upload = try #require(ClipExport.upload(for: item(manifest: manifest), duration: nil))
        let moments = upload.timeline.compactMap { entry -> Int? in
            if case .game = entry.event { entry.timestampMS } else { nil }
        }
        #expect(moments == [1_000, 3_000], "the death was cut; the triple plays 1 s into a 2× stretch that starts at 2 s")
        #expect(upload.durationSeconds == 4)
    }
}
