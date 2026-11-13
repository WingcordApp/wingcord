import AppKit
import AVFoundation
import Foundation
import WingcordCore
import WingcordVoice

// MARK: - The capture engine, run for real in `--demo`
//
// docs/CLIPS-PRESENCE.md, Phase 3.10. Tests drive the engine with made-up
// pictures; these drive it with ScreenCaptureKit on this Mac, without anybody
// clicking anything — so a check can run while the reader keeps working.
//
//   --clip-selftest <bundle id>   keeps that app's window as the game for
//                                 twelve seconds, then saves a clip
//   --record-selftest             records the main display for five seconds
//   --capture-bar                 opens the capture bar, to be looked at
//   --settings <section>          opens Settings at a pane (`SettingsSection`'s raw value)
//   --soundboard-wheel            opens the soundboard wheel at the pointer
//   --overlay-open                with --overlay: unlocked, the meter on, to be looked at
//   --game-profile                opens The Sims 4's profile
//   --game-communities            the same, on its Communities tab — one word on purpose:
//                                 AppKit reads a bare launch argument ("communities") as a
//                                 document to open, and SwiftUI then opens no window at all
//
// Each writes one line per step to the diagnostics log (`selftest`), and the
// files go to the demo's clips folder like any other.

enum DemoCaptureSelfTest {

    @MainActor
    static func runIfAsked(_ model: AppModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard LaunchOptions.current.usesDemoFixtures else { return }
        if let index = arguments.firstIndex(of: "--clip-selftest"), arguments.indices.contains(index + 1) {
            let bundleID = arguments[index + 1]
            Task { await clip(bundleID: bundleID, model: model) }
        }
        if arguments.contains("--record-selftest") {
            Task { await record(model: model) }
        }
        // A game's profile, open at launch — the fixture game with communities.
        if arguments.contains("--game-profile") || arguments.contains("--game-communities") {
            let communities = arguments.contains("--game-communities")
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                model.openGameProfile(DemoFixtures.sims)
                if communities { model.gameProfileInitialTab = .communities }
            }
        }
        // A settings pane, open at launch — the way to look at one without a
        // keystroke reaching whatever is in front.
        if let index = arguments.firstIndex(of: "--settings"), arguments.indices.contains(index + 1),
           let section = SettingsSection(rawValue: arguments[index + 1]) {
            Task {
                // The window's opener exists once the root view has appeared.
                for _ in 0 ..< 40 where !SettingsWindow.isRegistered {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .seconds(1))
                SettingsWindow.open(section)
            }
        }
        // The overlay open, every widget up — the meter included — so the
        // open state can be looked at without a key reaching the game.
        if arguments.contains("--overlay-open"), LaunchOptions.current.pretendsAGameIsRunning {
            Task {
                try? await Task.sleep(for: .seconds(3))
                var layout = model.overlay.layout
                layout.setEnabled(true, for: .performance)
                model.overlay.layout = layout
                model.overlay.setLocked(false)
            }
        }
        // The soundboard wheel, held open as its toggle key would leave it.
        if arguments.contains("--soundboard-wheel") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                model.soundboardWheel.attach(model)
                model.soundboardWheel.open(holding: false)
            }
        }
        // The call's full screen, in and out both ways — the window's own
        // exit (the green light, ⌃⌘F) and the call's Exit button — with what
        // the model believes logged at each step (Alex, 2026-10-22).
        if let index = arguments.firstIndex(of: "--call-fullscreen-selftest") {
            let mode = arguments.indices.contains(index + 1) ? arguments[index + 1] : "both"
            Task { await callFullScreen(model: model, mode: mode) }
        }
        // The bar itself, up at launch, to be looked at — `--overlay`'s idea.
        if arguments.contains("--capture-bar") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.capture.showBar()
            }
        }
    }

    @MainActor
    private static func clip(bundleID: String, model: AppModel) async {
        let note = { (line: String) in Log.info(.demo, .raw("selftest clip: \(line)")) }
        note("screen capture allowed: \(CGPreflightScreenCaptureAccess())")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return note("\(bundleID) is not running")
        }
        AppSettings.shared.clipsEnabled = true
        model.detectedGame = DetectedGame(
            id: ApplicationID(rawValue: 1), name: app.localizedName ?? bundleID, startedAt: .now,
            isLauncher: false, isTranslated: false, processIdentifier: app.processIdentifier
        )
        model.clipsSettingsChanged()
        note("armed on \(app.localizedName ?? bundleID) (pid \(app.processIdentifier))")
        try? await Task.sleep(for: .seconds(12))
        note("buffered: armed \(model.clipRecorder.isArmed), has pictures \(model.clipRecorder.hasPictures)")
        do {
            let url = try await model.clipRecorder.save(
                seconds: 30, to: ClipLibrary.folder, named: ClipLibrary.name(for: "Self Test"),
                context: model.clipSaveContext()
            )
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let video = (try? await asset.loadTracks(withMediaType: .video).count) ?? 0
            let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
            note("saved \(url.lastPathComponent): \(String(format: "%.1f", duration)) s, \(video) video, \(audio) audio")
        } catch {
            note("save failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func record(model: AppModel) async {
        let note = { (line: String) in Log.info(.demo, .raw("selftest record: \(line)")) }
        note("screen capture allowed: \(CGPreflightScreenCaptureAccess())")
        guard let display = NSScreen.main?.displayID else { return note("no display") }
        let package = ClipLibrary.availableURL(
            in: ClipLibrary.folder, named: ClipLibrary.name(for: "Self Test Recording"),
            extension: TakeManifest.pathExtension
        )
        try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let recording = ScreenRecording()
        do {
            let located = try await recording.start(
                .display(display), excluding: [], to: package.appendingPathComponent(TakeManifest.screenFile),
                settings: .init(framerate: 60, capturesSystemAudio: true, capturesMicrophone: false)
            )
            note("recording \(located.name) \(located.width)×\(located.height)")
            let frame = located.frame
            let cursor = CursorRecorder(frame: { frame }, start: { [weak recording] in recording?.startTime })
            cursor.begin()
            try? await Task.sleep(for: .seconds(5))
            let log = cursor.end()
            let url = try await recording.stop()
            try? JSONEncoder().encode(log).write(to: package.appendingPathComponent(TakeManifest.cursorFile))
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let video = try? await asset.loadTracks(withMediaType: .video).first
            let rate = (try? await video?.load(.nominalFrameRate)) ?? 0
            let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
            note("saved \(url.path): \(String(format: "%.1f", duration)) s at \(String(format: "%.0f", rate)) fps, \(audio) audio, \(log.samples.count) cursor samples")
        } catch {
            try? FileManager.default.removeItem(at: package)
            note("failed: \(error.localizedDescription)")
        }
    }

    /// Enters the call's full screen and leaves it twice: once the way the
    /// window's own controls do, once through the call's button.
    private static func callFullScreen(model: AppModel, mode: String) async {
        func note(_ step: String) {
            let window = MainWindow.workspaceWindow
            Log.info(
                .demo,
                .raw("fullscreen-selftest \(step): isCallFullScreen=\(model.isCallFullScreen) windowFullScreen=\(window?.styleMask.contains(.fullScreen) == true) window=\(window?.identifier?.rawValue ?? "nil")")
            )
            for each in NSApp.windows where each.isVisible {
                let content = each.contentView
                Log.info(
                    .demo,
                    .raw("fullscreen-selftest   window \(each.identifier?.rawValue ?? "-") \(type(of: each)) level=\(each.level.rawValue) frame=\(each.frame) content=\(content.map { "\(type(of: $0)) \($0.frame)" } ?? "nil") subviews=\(content?.subviews.map { "\(type(of: $0)) \($0.frame)" } ?? [])")
                )
            }
        }
        // The window first — a launch can come up without it until reopened.
        for _ in 0 ..< 40 where MainWindow.workspaceWindow == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(3))
        note("start")
        switch mode {
        case "plain":
            // The window alone, no call over it.
            MainWindow.workspaceWindow?.toggleFullScreen(nil)
            try? await Task.sleep(for: .seconds(3))
            note("window in")
            MainWindow.workspaceWindow?.toggleFullScreen(nil)
            try? await Task.sleep(for: .seconds(3))
            note("window out")
            return
        case "overlay":
            // The call over the workspace, the window left alone.
            model.isCallFullScreen = true
            try? await Task.sleep(for: .seconds(3))
            note("overlay in")
            model.isCallFullScreen = false
            try? await Task.sleep(for: .seconds(3))
            note("overlay out")
            return
        default:
            break
        }
        model.enterCallFullScreen()
        try? await Task.sleep(for: .seconds(3))
        note("entered")
        // The green light's way out.
        MainWindow.workspaceWindow?.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(3))
        note("after window exit")
        model.enterCallFullScreen()
        try? await Task.sleep(for: .seconds(3))
        note("entered again")
        model.exitCallFullScreen()
        try? await Task.sleep(for: .seconds(3))
        note("after button exit")
        try? await Task.sleep(for: .seconds(3))
        note("later")
    }
}
