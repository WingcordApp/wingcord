import AVFoundation
import Foundation
import WingcordCore

// MARK: - `--demo`'s clips library (docs/CLIPS-PRESENCE.md, Phase 4.6)
//
// | fixture | what it shows |
// | --- | --- |
// | "the bridge triple" — Battlefield 6, five people, kills, a laugh, today | a card's faces and game; the editor's marks; Share |
// | "team wipe" — the second game, two people, yesterday | the Games section; the date filter |
// | a recording of the desktop with its cursor log, three days ago | Recordings; the editor on a take |
// | two screenshots, one from last year | Screenshots; Last Year |
// | the first clip a favourite | Favourites |
//
// Written once into the demo's own folder (`~/Movies/Wingcord Demo Clips`)
// and never again: a fixture the reader deletes in the demo stays deleted.

enum DemoClipLibrary {

    private static let marker = "demo-fixtures"
    /// Phase 5's: the recording speaks, for captions and voice clean-up.
    private static let spokenMarker = "demo-fixtures-2"
    /// Phase 7's: Auto Clips — one kept, two waiting for review.
    private static let autoMarker = "demo-fixtures-3"

    /// Writes the library behind the window, once. `--demo` only: anywhere
    /// else this folder is the reader's own.
    static func populateIfNeeded(_ model: AppModel, people: [UserID]) {
        guard LaunchOptions.current.usesDemoFixtures else { return }
        let folder = ClipLibrary.folder
        let wingcord = folder.appendingPathComponent(".wingcord", isDirectory: true)
        let markerURL = wingcord.appendingPathComponent(marker)
        let spokenURL = wingcord.appendingPathComponent(spokenMarker)
        let autoURL = wingcord.appendingPathComponent(autoMarker)
        // Auto Clips, once, into any demo library — older ones included.
        if !FileManager.default.fileExists(atPath: autoURL.path(percentEncoded: false)) {
            let battlefield = DemoFixtures.battlefield.rawValue
            let review = ClipLibrary.reviewFolder
            Task {
                await writeAutoClips(into: folder, review: review, battlefield: battlefield)
                try? FileManager.default.createDirectory(at: wingcord, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: autoURL.path(percentEncoded: false), contents: Data())
                model.clipsRevision &+= 1
            }
        }
        if FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)) {
            // A library from before Phase 5: only its recording is new.
            guard !FileManager.default.fileExists(atPath: spokenURL.path(percentEncoded: false)) else { return }
            Task {
                await replaceSilentRecording(in: folder)
                FileManager.default.createFile(atPath: spokenURL.path(percentEncoded: false), contents: Data())
                model.clipsRevision &+= 1
            }
            return
        }
        let participants = people.compactMap { id in
            model.users[id].map { user in
                ClipParticipant(userID: id.rawValue, name: user.preferredName, avatarURL: model.avatarURL(for: user, side: 64))
            }
        }
        let battlefield = DemoFixtures.battlefield.rawValue
        Task {
            await write(into: folder, participants: participants, battlefield: battlefield)
            try? FileManager.default.createDirectory(at: wingcord, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: markerURL.path(percentEncoded: false), contents: Data())
            FileManager.default.createFile(atPath: spokenURL.path(percentEncoded: false), contents: Data())
            model.clipsRevision &+= 1
        }
    }

    /// Takes away the first demo's silent recording — known by its desktop's
    /// size and display name, which a real capture never has — and writes the
    /// speaking one.
    private static func replaceSilentRecording(in folder: URL) async {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for package in entries where package.pathExtension == TakeManifest.pathExtension {
            guard let take = ClipLibrary.take(in: package), !take.hasMicrophone,
                  take.width == Int(DemoMedia.desktopSize.width), take.height == Int(DemoMedia.desktopSize.height),
                  take.source == .display(name: demoDisplay)
            else { continue }
            try? FileManager.default.removeItem(at: package)
        }
        await writeRecording(into: folder, created: Date.now.addingTimeInterval(-3 * 86_400))
    }

    nonisolated private static let demoDisplay = "Built-in Retina Display"

    /// Off the main actor: encoding forty seconds of video is seconds of
    /// drawing.
    nonisolated private static func write(into folder: URL, participants: [ClipParticipant], battlefield: UInt64) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date.now
        let day = 86_400.0

        // The first game's clip: everybody, and the moments its picture
        // flashes at.
        let bridge = folder.appendingPathComponent("Battlefield 6 \(stamp(now.addingTimeInterval(-5 * 3_600))).mp4")
        await DemoMedia.encode(to: bridge, size: DemoMedia.gameClipSize, frames: Int(DemoMedia.gameClipSeconds * 30)) {
            DemoMedia.drawGame(frame: $0, in: $1)
        }
        let ids = participants.map(\.userID)
        func voice(_ index: Int, _ seconds: Double, on: Bool) -> ClipTimelineEvent? {
            guard ids.indices.contains(index) else { return nil }
            return ClipTimelineEvent(timestampMS: Int(seconds * 1_000), event: .speaking(userID: ids[index], flags: on ? 1 : 0))
        }
        let kills = DemoMedia.gameClipKills
        let bridgeTimeline: [ClipTimelineEvent] = [
            voice(0, 0, on: true), voice(0, 2.1, on: false), voice(2, 3.0, on: true),
            ClipTimelineEvent(timestampMS: Int(kills[0] * 1_000), event: .game(type: .kill, name: "Kill")),
            voice(2, 5.5, on: false), voice(1, 6.0, on: true),
            ClipTimelineEvent(timestampMS: Int(kills[1] * 1_000), event: .game(type: .kill, name: "Kill")),
            voice(1, 8.2, on: false), voice(0, 8.5, on: true), voice(3, 8.6, on: true),
            ClipTimelineEvent(timestampMS: Int(kills[2] * 1_000), event: .game(type: .multikill, name: "Triple Kill")),
            ClipTimelineEvent(timestampMS: 10_500, event: .emotion(.laughter)),
            voice(0, 12.0, on: false), voice(3, 13.0, on: false),
            ClipTimelineEvent(timestampMS: 14_000, event: .game(type: .death, name: "Death")),
            ClipTimelineEvent(timestampMS: 17_200, event: .game(type: .unknown, name: "Objective Captured")),
        ].compactMap(\.self)
        await finish(bridge, created: now.addingTimeInterval(-5 * 3_600), manifest: ClipManifest(
            createdAt: now.addingTimeInterval(-5 * 3_600), duration: DemoMedia.gameClipSeconds,
            title: "the bridge triple",
            game: ClipGame(applicationID: battlefield, name: "Battlefield 6"),
            participants: participants, timeline: bridgeTimeline
        ))

        // The second game's, yesterday, two people.
        let wipeKills = [2.5, 3.4, 4.1, 5.0]
        let wipe = folder.appendingPathComponent("Deadlock \(stamp(now.addingTimeInterval(-day - 2 * 3_600))).mp4")
        await DemoMedia.encode(to: wipe, size: DemoMedia.gameClipSize, frames: 12 * 30) {
            DemoMedia.drawGame(frame: $0, in: $1, look: .night, kills: wipeKills)
        }
        await finish(wipe, created: now.addingTimeInterval(-day - 2 * 3_600), manifest: ClipManifest(
            createdAt: now.addingTimeInterval(-day - 2 * 3_600), duration: 12, title: "team wipe",
            game: ClipGame(applicationID: nil, name: "Deadlock"),
            participants: Array(participants.prefix(2)),
            timeline: wipeKills.enumerated().map { index, seconds in
                ClipTimelineEvent(
                    timestampMS: Int(seconds * 1_000),
                    event: index == 3 ? .game(type: .multikill, name: "Team Wipe") : .game(type: .kill, name: "Kill")
                )
            } + [voice(0, 0, on: true), voice(0, 6, on: false)].compactMap(\.self)
        ))

        // A recording of the desktop, speaking, its cursor kept beside it.
        await writeRecording(into: folder, created: now.addingTimeInterval(-3 * day))

        // Two screenshots — one from last year, for the date filter.
        let shots: [(Date, Int, DemoMedia.GameLook)] = [
            (now.addingTimeInterval(-2 * 3_600), 290, .dusk),
            (Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now.addingTimeInterval(-400 * day), 60, .night),
        ]
        for (date, frame, look) in shots {
            let file = folder.appendingPathComponent("Screenshot \(stamp(date)).png")
            DemoMedia.writeStill(to: file, size: DemoMedia.gameClipSize, frame: frame) {
                DemoMedia.drawGame(frame: $0, in: $1, look: look, kills: [])
            }
            setCreated(date, of: file)
        }

        await MainActor.run {
            var favourites = ClipLibrary.favourites()
            favourites.insert(bridge.lastPathComponent)
            ClipLibrary.setFavourites(favourites)
        }
    }

    /// Phase 7.2's fixtures: a kept Auto Clip ("LOL") in the library, and two
    /// waiting in To Review — a Triple Kill and some shouting.
    nonisolated private static func writeAutoClips(into folder: URL, review: URL, battlefield: UInt64) async {
        try? FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        let now = Date.now
        let entries: [(folder: URL, minutesAgo: Double, look: DemoMedia.GameLook, reason: AutoClipReason)] = [
            (folder, 50, .dusk, AutoClipReason(kind: .laughter, name: "LOL", score: 1.12)),
            (review, 12, .night, AutoClipReason(kind: .gameEvent, name: "Triple Kill", score: 1.6)),
            (review, 4, .dusk, AutoClipReason(kind: .shouting, name: "Shouting", score: 1.05)),
        ]
        for entry in entries {
            let created = now.addingTimeInterval(-entry.minutesAgo * 60)
            let file = entry.folder.appendingPathComponent("Battlefield 6 \(stamp(created)).mp4")
            await DemoMedia.encode(to: file, size: DemoMedia.gameClipSize, frames: 8 * 30) {
                DemoMedia.drawGame(frame: $0 + 90, in: $1, look: entry.look)
            }
            var manifest = ClipManifest(
                createdAt: created, duration: 8,
                game: ClipGame(applicationID: battlefield, name: "Battlefield 6"),
                timeline: entry.reason.kind == .gameEvent
                    ? [ClipTimelineEvent(timestampMS: 3_000, event: .game(type: .multikill, name: "Triple Kill"))]
                    : [ClipTimelineEvent(
                        timestampMS: 3_000,
                        event: .emotion(entry.reason.kind == .laughter ? .laughter : .shouting)
                    )]
            )
            manifest.method = .auto
            manifest.autoReason = entry.reason
            await finish(file, created: created, manifest: manifest)
        }
    }

    /// The desktop recording: eight seconds of a window scrolling, the
    /// cursor's log beside it with two clicks for Smart Zoom, and a voice on
    /// the microphone track for captions and voice clean-up.
    nonisolated private static func writeRecording(into folder: URL, created: Date) async {
        let package = folder.appendingPathComponent("Recording \(stamp(created)).\(TakeManifest.pathExtension)", isDirectory: true)
        try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let screen = package.appendingPathComponent(TakeManifest.screenFile)
        let voice = FileManager.default.temporaryDirectory.appendingPathComponent("demo-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: voice) }
        let speaks = await DemoMedia.speak(DemoMedia.recordingWords, to: voice)
        await DemoMedia.encode(
            to: screen, size: DemoMedia.desktopSize, frames: 8 * 30, fileType: .mov, voice: speaks ? voice : nil
        ) { DemoMedia.drawDesktop(frame: $0, in: $1) }
        var log = CursorLog()
        for step in 0...80 {
            let t = Double(step) * 0.1
            log.samples.append(.init(
                t: t, x: 0.25 + 0.5 * (t / 8), y: 0.4 + 0.15 * sin(t), kind: step > 40 && step < 60 ? .iBeam : .arrow
            ))
        }
        log.clicks = [
            .init(t: 2.0, x: 0.375, y: 0.53, button: 0, isDown: true),
            .init(t: 2.1, x: 0.375, y: 0.53, button: 0, isDown: false),
            .init(t: 6.0, x: 0.625, y: 0.36, button: 0, isDown: true),
            .init(t: 6.1, x: 0.625, y: 0.36, button: 0, isDown: false),
        ]
        try? JSONEncoder().encode(log).write(to: package.appendingPathComponent(TakeManifest.cursorFile))
        let take = TakeManifest(
            createdAt: created, duration: 8, source: .display(name: demoDisplay),
            width: Int(DemoMedia.desktopSize.width), height: Int(DemoMedia.desktopSize.height), framerate: 30,
            hasSystemAudio: false, hasMicrophone: speaks, hasCamera: false, hasCursorLog: true
        )
        await MainActor.run { ClipLibrary.writeTake(take, in: package) }
        setCreated(created, of: package)
    }

    private static func finish(_ file: URL, created: Date, manifest: ClipManifest) {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        ClipLibrary.writeManifest(manifest, for: file)
        setCreated(created, of: file)
    }

    /// The library sorts and filters by the file's own date.
    nonisolated private static func setCreated(_ date: Date, of file: URL) {
        try? FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date], ofItemAtPath: file.path(percentEncoded: false)
        )
    }

    /// `ClipLibrary.name(for:at:)`'s stamp, so a fixture is named as a real
    /// save would be.
    nonisolated private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
