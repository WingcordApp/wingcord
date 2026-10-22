import AppKit
import AVFoundation
import Foundation
import Observation
import OSLog
import WingcordCore
import WingcordVoice

// MARK: - The capture bar's brain
//
// docs/CLIPS-PRESENCE.md, D12 / Phase 3.7–3.8. Record the screen, a window or
// an area — with the camera, the microphone and the system's sound as files and
// tracks of their own, the cursor left out and logged — or take a screenshot of
// any of the three. A take lands in the clips folder as a
// `<name>.wingcordtake` package (`TakeManifest`), a screenshot as a PNG.
//
// **Asked for only when used** (HIG: "wait until people use a feature that
// requires it"): Screen Recording when the first capture starts, the camera
// when its switch is turned on, the microphone when a recording with it does.

@Observable
@MainActor
final class CaptureController {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Capture")

    enum Phase: Equatable {
        case idle
        /// The overlays are up, waiting for a choice.
        case choosing
        case recording(since: Date)
        /// Writing the files out.
        case finishing
    }

    // MARK: Options, kept between launches

    var target: CaptureTarget = .display {
        didSet { defaults.set(target.rawValue, forKey: Key.target) }
    }
    var usesCamera = false {
        didSet {
            defaults.set(usesCamera, forKey: Key.camera)
            usesCamera ? openCamera() : closeCamera()
        }
    }
    var usesMicrophone = true {
        didSet { defaults.set(usesMicrophone, forKey: Key.microphone) }
    }
    var usesSystemAudio = true {
        didSet { defaults.set(usesSystemAudio, forKey: Key.systemAudio) }
    }
    /// 30, 60 or 120 — D12's ceiling.
    var framerate = 60 {
        didSet { defaults.set(framerate, forKey: Key.framerate) }
    }
    static let framerates = [30, 60, 120]

    private(set) var phase: Phase = .idle
    private(set) var isBarShown = false
    /// The last thing that did not work, said on the bar.
    private(set) var failure: String?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let picker = CaptureTargetPicker()
    @ObservationIgnored private var bar: CaptureBarPanel?
    @ObservationIgnored private var pill: CaptureBarPanel?
    @ObservationIgnored private var bubble: CameraBubblePanel?
    @ObservationIgnored private var statusItem: CaptureStatusItem?
    @ObservationIgnored private var recording: ScreenRecording?
    @ObservationIgnored private var cursor: CursorRecorder?
    @ObservationIgnored private var camera: CameraTake?
    @ObservationIgnored private var take: (package: URL, located: ScreenRecording.Located, source: TakeManifest.Source, settings: ScreenRecording.Settings, started: Date)?

    init() {
        target = defaults.string(forKey: Key.target).flatMap(CaptureTarget.init(rawValue:)) ?? .display
        usesMicrophone = defaults.object(forKey: Key.microphone) as? Bool ?? true
        usesSystemAudio = defaults.object(forKey: Key.systemAudio) as? Bool ?? true
        framerate = defaults.object(forKey: Key.framerate) as? Int ?? 60
        // The camera is never on at launch: a light coming on by itself is
        // not something an app gets to do.
        usesCamera = false
    }

    // MARK: The bar

    func toggleBar() {
        isBarShown ? hideBar() : showBar()
    }

    func showBar() {
        guard phase == .idle else { return }
        failure = nil
        let bar = self.bar ?? CaptureBarPanel(content: CaptureBar(controller: self))
        bar.onCancel = { [weak self] in self?.hideBar() }
        self.bar = bar
        bar.place(onScreenWith: NSEvent.mouseLocation, edge: .bottom)
        // **It takes the keyboard**, as macOS's own capture bar does: it was
        // just asked for, Escape closes it, and only a window with the
        // keyboard draws its Record as the red glass it is. Not the app — the
        // panel is non-activating, so nothing behind it comes forward.
        bar.makeKeyAndOrderFront(nil)
        isBarShown = true
        if usesCamera { openCamera() }
    }

    func hideBar() {
        bar?.orderOut(nil)
        isBarShown = false
        if !isRecording { closeCamera() }
    }

    // MARK: Capturing

    /// The bar's Record: choose, then record.
    func record() {
        Task { await capture(recording: true) }
    }

    /// The bar's Screenshot: choose, then take it.
    func screenshot() {
        Task { await capture(recording: false) }
    }

    /// Start or stop, from a key or a Shortcut: what the bar would do with
    /// its current choices — the display under the pointer for "Screen".
    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else if phase == .idle {
            Task { await capture(recording: true) }
        }
    }

    private func capture(recording isRecording: Bool) async {
        guard phase == .idle else { return }
        failure = nil
        let wasShown = isBarShown
        bar?.orderOut(nil)
        bubble?.orderOut(nil)
        phase = .choosing
        let choice = await picker.choose(target, excluding: ownWindows)
        guard let choice else {
            phase = .idle
            if wasShown { showBar() }
            return
        }
        phase = .idle
        let source: ScreenRecording.Source = switch choice {
        case .display(let id): .display(id)
        case .window(let id): .window(id)
        case .area(let id, let rect): .area(id, rect)
        }
        if isRecording {
            await startRecording(source)
        } else {
            await takeScreenshot(source)
            if wasShown { showBar() }
        }
    }

    // MARK: Recording

    private func startRecording(_ source: ScreenRecording.Source) async {
        let folder = ClipLibrary.folder
        let name = ClipLibrary.name(for: "Recording")
        let package = ClipLibrary.availableURL(in: folder, named: name, extension: TakeManifest.pathExtension)
        do {
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        } catch {
            return fail("The recording has nowhere to go: \(error.localizedDescription)")
        }
        let settings = ScreenRecording.Settings(
            framerate: framerate, capturesSystemAudio: usesSystemAudio, capturesMicrophone: usesMicrophone,
            microphoneID: AppSettings.shared.voiceInputDeviceID
        )
        let recording = ScreenRecording()
        recording.onStop = { [weak self] reason in
            Task { @MainActor in
                self?.failure = reason
                await self?.stopRecording()
            }
        }
        // The pill and the bubble are on screen while it records; they are
        // left out of the picture.
        showPill()
        if usesCamera { showBubble(onDisplayOf: source) }
        let located: ScreenRecording.Located
        do {
            located = try await recording.start(
                source, excluding: ownWindows,
                to: package.appendingPathComponent(TakeManifest.screenFile), settings: settings
            )
        } catch {
            hidePill()
            bubble?.orderOut(nil)
            try? FileManager.default.removeItem(at: package)
            return fail(error.localizedDescription)
        }
        self.recording = recording
        let frame = located.frame
        let cursor = CursorRecorder(frame: { frame }, start: { [weak recording] in recording?.startTime })
        cursor.begin()
        self.cursor = cursor
        if usesCamera, let camera {
            camera.record(to: package.appendingPathComponent(TakeManifest.cameraFile))
        }
        let takeSource: TakeManifest.Source = switch source {
        case .display: .display(name: located.name)
        case .window: .window(title: located.name, application: located.application ?? "")
        case .area(_, let rect): .area(display: located.name, rect: rect)
        }
        take = (package, located, takeSource, settings, .now)
        phase = .recording(since: .now)
        showStatusItem()
        Self.log.info("capture: recording into \(package.lastPathComponent, privacy: .public)")
    }

    /// Stops, writes the take out, and says where it went.
    func stopRecording() async {
        guard isRecording, let recording, let take else { return }
        phase = .finishing
        let log = cursor?.end()
        cursor = nil
        let screenStart = recording.startTime
        let screen: URL
        do {
            screen = try await recording.stop()
        } catch {
            finishUp()
            return fail(error.localizedDescription)
        }
        var cameraOffset = 0.0
        var hasCamera = false
        if let camera, await camera.finish() != nil {
            hasCamera = true
            if let screenStart, let cameraStart = camera.startTime { cameraOffset = cameraStart - screenStart }
        }
        let duration = (try? await AVURLAsset(url: screen).load(.duration).seconds) ?? Date.now.timeIntervalSince(take.started)
        if let log {
            let encoder = JSONEncoder()
            try? encoder.encode(log).write(to: take.package.appendingPathComponent(TakeManifest.cursorFile))
        }
        let manifest = TakeManifest(
            createdAt: take.started, duration: duration, source: take.source,
            width: take.located.width, height: take.located.height, framerate: take.settings.framerate,
            hasSystemAudio: take.settings.capturesSystemAudio, hasMicrophone: take.settings.capturesMicrophone,
            hasCamera: hasCamera, cameraOffset: cameraOffset, hasCursorLog: log != nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(manifest).write(to: take.package.appendingPathComponent(TakeManifest.fileName))
        finishUp()
        model?.clipsRevision &+= 1
        model?.reportSuccess("Recording saved — \(Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond))).")
        Self.log.info("capture: saved \(take.package.lastPathComponent, privacy: .public)")
    }

    /// Stops and throws the take away.
    func discardRecording() {
        guard isRecording, let take else { return }
        Task {
            _ = cursor?.end()
            cursor = nil
            _ = try? await recording?.stop()
            _ = await camera?.finish()
            try? FileManager.default.removeItem(at: take.package)
            finishUp()
        }
    }

    private func finishUp() {
        recording = nil
        take = nil
        phase = .idle
        hidePill()
        hideStatusItem()
        bubble?.orderOut(nil)
        if !isBarShown { closeCamera() }
    }

    // MARK: Screenshots

    private func takeScreenshot(_ source: ScreenRecording.Source) async {
        do {
            let image = try await ScreenRecording.screenshot(source, excluding: ownWindows)
            let folder = ClipLibrary.folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = ClipLibrary.availableURL(in: folder, named: ClipLibrary.name(for: "Screenshot"), extension: "png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                return fail("Could not create \(url.lastPathComponent).")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return fail("Could not write \(url.lastPathComponent).") }
            model?.clipsRevision &+= 1
            model?.reportSuccess("Screenshot saved.")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ reason: String) {
        failure = reason
        phase = .idle
        model?.reportActionFailure(reason)
        Self.log.warning("capture: \(reason, privacy: .public)")
    }

    // MARK: The camera

    private func openCamera() {
        guard camera == nil else {
            if isBarShown { showBubble(onDisplayOf: nil) }
            return
        }
        let camera = CameraTake()
        do {
            try camera.open(deviceID: AppSettings.shared.cameraDeviceID)
        } catch {
            failure = error.localizedDescription
            return
        }
        self.camera = camera
        if isBarShown || isRecording { showBubble(onDisplayOf: nil) }
    }

    private func closeCamera() {
        bubble?.orderOut(nil)
        bubble = nil
        camera?.close()
        camera = nil
    }

    private func showBubble(onDisplayOf source: ScreenRecording.Source?) {
        guard let camera else { return }
        let bubble = self.bubble ?? CameraBubblePanel(session: camera.handle)
        self.bubble = bubble
        if !bubble.isVisible { bubble.placeInCorner(of: Self.screen(for: source)) }
        bubble.orderFrontRegardless()
    }

    private static func screen(for source: ScreenRecording.Source?) -> NSScreen? {
        let id: CGDirectDisplayID? = switch source {
        case .display(let id), .area(let id, _): id
        case .window, .none: nil
        }
        if let id, let screen = NSScreen.screens.first(where: { $0.displayID == id }) { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    // MARK: While recording

    private func showPill() {
        let pill = self.pill ?? CaptureBarPanel(content: CaptureRecordingPill(controller: self))
        self.pill = pill
        pill.place(onScreenWith: NSEvent.mouseLocation, edge: .top)
        pill.orderFrontRegardless()
    }

    private func hidePill() {
        pill?.orderOut(nil)
    }

    private func showStatusItem() {
        let item = statusItem ?? CaptureStatusItem(controller: self)
        statusItem = item
        item.show()
    }

    private func hideStatusItem() {
        statusItem?.hide()
    }

    /// The capture's own windows, which never appear in what it captures.
    private var ownWindows: Set<CGWindowID> {
        var windows: [NSWindow] = []
        if let bar { windows.append(bar) }
        if let pill { windows.append(pill) }
        if let bubble { windows.append(bubble) }
        return Set(windows.map { CGWindowID($0.windowNumber) })
    }

    private enum Key {
        static let target = "capture.target"
        static let camera = "capture.camera"
        static let microphone = "capture.microphone"
        static let systemAudio = "capture.systemAudio"
        static let framerate = "capture.framerate"
    }
}
