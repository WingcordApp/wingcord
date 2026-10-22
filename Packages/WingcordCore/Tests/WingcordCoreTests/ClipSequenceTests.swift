import CoreGraphics
import Foundation
import Testing
@testable import WingcordCore

/// Editor v2's model (docs/CLIPS-PRESENCE.md, Phase 5.1): cuts and speed on
/// two clocks, and what it lays on a clip.
struct ClipSequenceTests {

    @Test("A v1 trim is one segment; cutting it maps both clocks through the cut and the speed")
    func sequence() throws {
        var edits = ClipEdits(start: 2, end: 12)
        #expect(edits.sequence(in: 20).duration == 10)
        #expect(edits.resolvedSegments(in: 20).first?.id == ClipEdits.wholeSegmentID)

        // Split at 4 s of output (6 s of source), drop the first half, play
        // the rest at 2×.
        let cut = edits.split(atOutput: 4, duration: 20)
        let second = try #require(cut)
        #expect(edits.segments.count == 2)
        let first = edits.segments[0].id
        edits.removeSegment(first, duration: 20)
        edits.setSpeed(2, of: second, duration: 20)
        let sequence = edits.sequence(in: 20)
        #expect(sequence.duration == 3, "6…12 s at 2× is 3 s")
        #expect(edits.start == 6 && edits.end == 12, "the v1 trim follows the outer ends")
        #expect(sequence.sourceTime(atOutput: 1) == 8)
        #expect(sequence.outputTime(atSource: 9) == 1.5)
        #expect(sequence.outputTime(atSource: 3) == nil, "a cut moment does not play")
        #expect(sequence.sourceTime(atOutput: 99) == 12, "clamped to the end")
    }

    @Test("A stretch of the source plays once per segment it falls in")
    func ranges() {
        var edits = ClipEdits()
        edits.setSegments([
            ClipSegment(start: 0, end: 4),
            ClipSegment(start: 6, end: 10, speed: 2),
        ])
        let sequence = edits.sequence(in: 10)
        let ranges = sequence.outputRanges(ofSource: 3...8)
        #expect(ranges == [3...4, 4...5])
        #expect(sequence.outputRanges(ofSource: 4.5...5.5).isEmpty)
    }

    @Test("Splits and trims keep segments apart and never shorter than the minimum")
    func limits() {
        var edits = ClipEdits()
        let early = edits.split(atOutput: 0.05, duration: 10)
        #expect(early == nil, "too near the start")
        let second = edits.split(atOutput: 5, duration: 10)
        #expect(second != nil)
        let first = edits.segments[0].id
        edits.trimSegment(first, end: 9, duration: 10)
        #expect(edits.segments[0].end == 5, "not past the next one")
        edits.trimSegment(first, end: 0, duration: 10)
        #expect(edits.segments[0].end == ClipSegment.minimumLength)
        edits.removeSegment(first, duration: 10)
        edits.removeSegment(edits.segments.first?.id ?? first, duration: 10)
        #expect(edits.resolvedSegments(in: 10).count == 1, "the last segment stays")
        edits.setSpeed(9, of: edits.resolvedSegments(in: 10)[0].id, duration: 10)
        #expect(edits.resolvedSegments(in: 10)[0].speed == ClipSegment.speeds.upperBound)
    }

    @Test("Zoom blocks ease in and out; the strongest wins; follow the cursor when asked")
    func zoom() {
        let block = ZoomBlock(start: 1, end: 3, scale: 2, x: 0.8, y: 0.2)
        #expect(block.weight(at: 0.5) == 0)
        #expect(block.weight(at: 2) == 1)
        let rising = block.weight(at: 1 + ZoomBlock.transition / 2)
        #expect(rising > 0 && rising < 1)

        let zooms = [block, ZoomBlock(start: 1.5, end: 2.5, scale: 3, x: 0.1, y: 0.1, followsCursor: true)]
        let state = zooms.state(at: 2, cursor: CGPoint(x: 0.6, y: 0.7))
        #expect(state.scale == 3)
        #expect(state.x == 0.6 && state.y == 0.7)
        #expect(zooms.state(at: 5) == .none)

        let edge = ZoomState(scale: 2, x: 0.95, y: 0.5).visibleRect
        #expect(edge.maxX == 1 && edge.width == 0.5, "held inside the picture")
    }

    @Test("Smart Zoom puts one zoom on each run of clicks, centred on them")
    func smartZoom() {
        var log = CursorLog()
        log.clicks = [
            .init(t: 1, x: 0.2, y: 0.2, button: 0, isDown: true),
            .init(t: 1.1, x: 0.2, y: 0.2, button: 0, isDown: false),
            .init(t: 2.5, x: 0.4, y: 0.2, button: 0, isDown: true),
            .init(t: 8, x: 0.9, y: 0.9, button: 0, isDown: true),
            .init(t: 9, x: 0.5, y: 0.5, button: 1, isDown: true),
        ]
        let blocks = SmartZoom.suggestions(from: log, duration: 9)
        #expect(blocks.count == 2)
        #expect(abs(blocks[0].x - 0.3) < 0.0001 && blocks[0].start == 0.4)
        #expect(blocks[1].end == 9, "clamped to the recording")
        #expect(blocks.allSatisfy { $0.isSuggested })
    }

    @Test("The canvas: Auto pads the picture's own shape; a fixed shape fits it inside")
    func canvas() {
        let plain = ClipCanvas.plain.layout(contentAspect: 16.0 / 9.0)
        #expect(abs(plain.canvasAspect - 16.0 / 9.0) < 0.0001)
        #expect(plain.content == CGRect(x: 0, y: 0, width: 1, height: 1))

        let padded = ClipCanvas(padding: 0.1).layout(contentAspect: 1)
        #expect(abs(padded.canvasAspect - 1) < 0.0001)
        #expect(abs(padded.content.width - 1 / 1.2) < 0.0001)

        let portrait = ClipCanvas(aspect: .portrait).layout(contentAspect: 16.0 / 9.0)
        #expect(abs(portrait.canvasAspect - 9.0 / 16.0) < 0.0001)
        #expect(abs(portrait.content.width - 1) < 0.0001, "a wide picture fills the width of a tall canvas")
        #expect(portrait.content.height < 0.4)
        #expect(ClipCanvas.plain.isPlain && !ClipCanvas(padding: 0.05).isPlain)
    }

    @Test("Words become lines at a pause, a length, or a duration")
    func captions() {
        let words = [
            Caption.Word(text: "no", start: 0, end: 0.2), .init(text: "way", start: 0.25, end: 0.5),
            .init(text: "this", start: 0.55, end: 0.7), .init(text: "worked", start: 0.75, end: 1.1),
            .init(text: "again", start: 2.5, end: 2.8),
        ]
        let lines = Caption.lines(from: words)
        #expect(lines.map(\.text) == ["no way this worked", "again"])
        #expect(lines[0].start == 0 && lines[0].end == 1.1)
        let long = (0..<20).map { Caption.Word(text: "word\($0)", start: Double($0) * 0.1, end: Double($0) * 0.1 + 0.08) }
        #expect(Caption.lines(from: long).allSatisfy { $0.text.count <= 42 })
    }

    @Test("A v1 sidecar's edits still read; v2's round-trip")
    func decoding() throws {
        let v1 = #"{"start":1.5,"end":9,"crop":"portrait","cropPosition":0.3,"mutedTracks":[2],"texts":[],"images":[]}"#
        let old = try JSONDecoder().decode(ClipEdits.self, from: Data(v1.utf8))
        #expect(old.start == 1.5 && old.crop == .portrait && old.mutedTracks == [2])
        #expect(old.segments.isEmpty && old.canvas.isPlain && old.cursor.isVisible)

        var edits = ClipEdits()
        edits.setSegments([ClipSegment(start: 0, end: 2), ClipSegment(start: 3, end: 5, speed: 0.5)])
        edits.zooms = [ZoomBlock(start: 1, end: 2)]
        edits.canvas = ClipCanvas.presets[0].canvas
        edits.blurs = [BlurRegion(start: 0, end: 1)]
        edits.captions = [Caption(start: 0, end: 1, text: "hi")]
        edits.cleanedStems = [1]
        edits.burnsInSpeaking = true
        let back = try JSONDecoder().decode(ClipEdits.self, from: JSONEncoder().encode(edits))
        #expect(back == edits)
        #expect(!edits.isEmpty)
    }
}
