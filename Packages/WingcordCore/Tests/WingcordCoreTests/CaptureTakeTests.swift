import CoreGraphics
import Foundation
import Testing
@testable import WingcordCore

/// A capture bar take's description and its cursor log (docs/CLIPS-PRESENCE.md,
/// Phase 3.7).
@Suite("Capture take")
struct CaptureTakeTests {

    @Test("The cursor is kept in the picture's own frame, 0…1 from its top left")
    func normalise() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 400)
        let inside = CursorLog.normalise(CGPoint(x: 500, y: 250), in: window)
        #expect(inside.x == 0.5 && inside.y == 0.5 && !inside.isOutside)
        let outside = CursorLog.normalise(CGPoint(x: 50, y: 250), in: window)
        #expect(outside.isOutside)
        #expect(CursorLog.normalise(.zero, in: .zero).isOutside)
    }

    @Test("Between samples the cursor is where it was going")
    func interpolates() {
        var log = CursorLog()
        log.samples = [
            .init(t: 0, x: 0, y: 0, kind: .arrow),
            .init(t: 1, x: 1, y: 0.5, kind: .pointingHand),
        ]
        let middle = log.position(at: 0.5)
        #expect(middle?.x == 0.5 && middle?.y == 0.25)
        #expect(log.position(at: 2)?.x == 1, "after the last sample it stays there")
        #expect(log.position(at: -1)?.x == 0)
    }

    @Test("A take's description survives a round trip, the area's rectangle with it")
    func roundTrip() throws {
        let take = TakeManifest(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), duration: 12.5,
            source: .area(display: "Built-in Display", rect: CGRect(x: 10, y: 20, width: 300, height: 200)),
            width: 600, height: 400, framerate: 120, hasSystemAudio: true, hasMicrophone: true,
            hasCamera: true, cameraOffset: 0.08, hasCursorLog: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TakeManifest.self, from: encoder.encode(take)) == take)
        #expect(take.summary == "Part of the screen")
        #expect(TakeManifest(
            createdAt: .now, duration: 1, source: .window(title: "Notes", application: "Safari"),
            width: 2, height: 2, framerate: 60, hasSystemAudio: false, hasMicrophone: false,
            hasCamera: false, hasCursorLog: false
        ).summary == "Safari — Notes")
    }
}
