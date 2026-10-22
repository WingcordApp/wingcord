import Foundation
import Testing
@testable import WingcordCore

/// Discord's `clip_events_timeline`, built as module 762555's `lz` builds it.
@Suite("Clip timeline")
struct ClipManifestTests {

    private let alex: UInt64 = 1
    private let sam: UInt64 = 2
    private let kai: UInt64 = 3

    @Test("Whoever is already speaking starts at 0; later changes are milliseconds in")
    func carriedState() {
        let events = ClipTimeline.events(start: 100, end: 130, speaking: [
            .init(time: 90, userID: alex, flags: 1),
            .init(time: 95, userID: sam, flags: 1),
            .init(time: 98, userID: sam, flags: 0),
            .init(time: 101.25, userID: kai, flags: 1),
            .init(time: 104, userID: alex, flags: 0),
        ])
        #expect(events == [
            .init(timestampMS: 0, event: .speaking(userID: alex, flags: 1)),
            .init(timestampMS: 1_250, event: .speaking(userID: kai, flags: 1)),
            .init(timestampMS: 4_000, event: .speaking(userID: alex, flags: 0)),
        ])
    }

    @Test("A change that changes nothing is not an entry; one past the end is not either")
    func dedupesAndClips() {
        let events = ClipTimeline.events(start: 0, end: 10, speaking: [
            .init(time: 1, userID: alex, flags: 1),
            .init(time: 2, userID: alex, flags: 1),
            .init(time: 3, userID: alex, flags: 5),
            .init(time: 4, userID: alex, flags: 0),
            .init(time: 4.5, userID: sam, flags: 0),
            .init(time: 11, userID: alex, flags: 1),
        ])
        // Priority speech is still speech: the flags carry the voice bit.
        #expect(events.map(\.timestampMS) == [1_000, 4_000])
    }

    @Test("Game events and emotions sit beside speech, sorted, and the cap holds")
    func mixedAndCapped() {
        let events = ClipTimeline.events(
            start: 10, end: 40,
            speaking: [.init(time: 20, userID: alex, flags: 1)],
            games: [.init(time: 15, type: .kill, name: "Double Kill"), .init(time: 50, type: .death, name: "late")],
            emotions: [.init(time: 20, emotion: .laughter)]
        )
        #expect(events == [
            .init(timestampMS: 5_000, event: .game(type: .kill, name: "Double Kill")),
            .init(timestampMS: 10_000, event: .speaking(userID: alex, flags: 1)),
            .init(timestampMS: 10_000, event: .emotion(.laughter)),
        ])

        let many = (0..<1_500).map { ClipTimeline.SpeakingChange(time: Double($0) * 0.01, userID: alex, flags: $0 % 2) }
        #expect(ClipTimeline.events(start: 0, end: 100, speaking: many).count == ClipTimeline.eventLimit)
    }

    @Test("It travels in Discord's own shape")
    func wireShape() throws {
        let timeline: [ClipTimelineEvent] = [
            .init(timestampMS: 0, event: .speaking(userID: 1_520_000_000_000_000_001, flags: 1)),
            .init(timestampMS: 420, event: .game(type: .multikill, name: "Triple Kill")),
            .init(timestampMS: 900, event: .emotion(.shouting)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(timeline), as: UTF8.self)
        #expect(json == #"[{"speaking":{"speaking_flags":1,"user_id":"1520000000000000001"},"timestamp_ms":0},"#
            + #"{"game":{"event_name":"Triple Kill","type":2},"timestamp_ms":420},"#
            + #"{"emotion":{"type":2},"timestamp_ms":900}]"#)
        #expect(try JSONDecoder().decode([ClipTimelineEvent].self, from: Data(json.utf8)) == timeline)
    }

    @Test("A manifest survives a round trip, and names its first hundred participants")
    func manifestRoundTrip() throws {
        var manifest = ClipManifest(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            duration: 30,
            game: ClipGame(applicationID: 356_875_570_920_743_315, name: "Minecraft"),
            participants: (1...120).map { ClipParticipant(userID: UInt64($0), name: "P\($0)") },
            tracks: [
                ClipAudioTrack(role: .mix, title: "Everything", isEnabled: true),
                ClipAudioTrack(role: .voice(userID: 7), title: "Kim", isEnabled: false),
            ]
        )
        manifest.timeline = [.init(timestampMS: 0, event: .speaking(userID: 7, flags: 1))]
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(ClipManifest.self, from: data) == manifest)
        #expect(manifest.participantIDs.count == ClipTimeline.participantLimit)
        #expect(manifest.participantIDs.first == "1")
    }
}

/// The editor's metadata (docs/CLIPS-PRESENCE.md, Phase 4.3).
@Suite("Clip edits")
struct ClipEditsTests {

    @Test("Discord's crop presets cut the most of the picture they can, and slide along the free axis")
    func crop() {
        let wide = CGSize(width: 3440, height: 1440)
        #expect(CropPreset.original.rect(in: wide, position: 0.5) == CGRect(origin: .zero, size: wide))
        let landscape = CropPreset.landscape.rect(in: wide, position: 0.5)
        #expect(landscape.height == 1440 && landscape.width == 2560 && landscape.minX == 440)
        let portrait = CropPreset.portrait.rect(in: CGSize(width: 1920, height: 1080), position: 0)
        #expect(portrait.minX == 0 && portrait.height == 1080 && portrait.width == 607)
        let tall = CropPreset.landscape.rect(in: CGSize(width: 1080, height: 1920), position: 1)
        #expect(tall.width == 1080 && tall.maxY == 1920)
    }

    @Test("A trim keeps the stretch inside the file, and the timeline is cut to it")
    func trim() {
        var edits = ClipEdits(start: -3, end: 99)
        #expect(edits.range(in: 30) == 0...30)
        edits = ClipEdits(start: 10, end: 5)
        #expect(edits.range(in: 30) == 10...10)
        #expect(ClipEdits().isEmpty)
        #expect(!ClipEdits(crop: .portrait).isEmpty)

        var manifest = ClipManifest(createdAt: .now, duration: 30)
        manifest.timeline = [
            .init(timestampMS: 0, event: .speaking(userID: 7, flags: 1)),
            .init(timestampMS: 12_000, event: .game(type: .kill, name: "Kill")),
            .init(timestampMS: 25_000, event: .speaking(userID: 7, flags: 0)),
        ]
        let cut = manifest.timeline(trimmedTo: 10...20)
        #expect(cut == [
            .init(timestampMS: 0, event: .speaking(userID: 7, flags: 1)),
            .init(timestampMS: 2_000, event: .game(type: .kill, name: "Kill")),
        ])
    }
}
