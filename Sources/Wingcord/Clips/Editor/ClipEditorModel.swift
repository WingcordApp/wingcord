import AVFoundation
import AppKit
import Foundation
import Observation
import WingcordCore
import WingcordVoice

// MARK: - One clip, open in the editor
//
// docs/CLIPS-PRESENCE.md, D14 — Discord's editor (Phase 4.3) grown into a
// Slice-class one (Phase 5): the preview plays **the edit itself** — the same
// render graph the export writes, so cuts, speed, the canvas, zooms, blurs,
// the cursor, words, pictures and captions are on screen as they will be in
// the file. A drag changes only the picture plan, swapped into the playing
// item; a cut or a sound switched rebuilds the composition. Every change is
// written to the clip's sidecar a moment later — edits are metadata, the
// file is untouched — and each is undoable.

@Observable
@MainActor
final class ClipEditorModel {

    /// One audio track the editor can switch off — Discord's Audio, Speaker
    /// and Soundboard rows — and, for a voice, clean up.
    struct Stem: Identifiable, Hashable {
        /// Its place among the file's audio tracks.
        var index: Int
        var title: String
        var symbolName: String
        /// A person's voice or the microphone — what voice clean-up is for.
        var isVoice: Bool
        var id: Int { index }
    }

    /// What the inspector edits.
    enum Selection: Hashable {
        case segment(UUID)
        case overlay(UUID)
        case zoom(UUID)
        case blur(UUID)
        case caption(UUID)
    }

    enum CaptionState: Equatable {
        case idle
        case working(CaptionTranscriber.Stage)
        case failed(String)
    }

    let item: ClipLibraryItem
    var edits: ClipEdits {
        didSet {
            guard edits != oldValue else { return }
            editsChanged(from: oldValue)
            scheduleSave()
        }
    }
    var title: String {
        didSet { if title != oldValue { scheduleSave() } }
    }
    /// The source file's length.
    private(set) var sourceDuration: Double = 0
    /// The edit's own clock: the kept stretches end to end at their speeds.
    private(set) var sequence = ClipSequence(segments: [])
    /// The picture's own size, in pixels.
    private(set) var videoSize: CGSize = .zero
    /// The canvas the preview shows, in its pixels.
    private(set) var renderSize: CGSize = CGSize(width: 16, height: 9)
    /// Where the playhead is, on the edit's clock.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    /// Pictures along the source, each with its time in the source.
    private(set) var filmstrip: [(time: Double, image: CGImage)] = []
    /// The sound's loudness along the source, 0…1, one value a bucket.
    private(set) var waveform: [Float] = []
    private(set) var stems: [Stem] = []
    var selection: Selection?
    private(set) var isLoaded = false
    /// The crop is being set on the source picture, not watched in the edit.
    var isAdjustingCrop = false {
        didSet { if isAdjustingCrop { pause(); refreshCropStill() } }
    }
    private(set) var cropStill: CGImage?
    let cursorLog: CursorLog?
    var captionState: CaptionState = .idle
    /// Stems being cleaned now.
    private(set) var cleaningStems: Set<Int> = []
    private(set) var cleanUpFailure: String?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var redrawTask: Task<Void, Never>?
    @ObservationIgnored private var graph: ClipRenderGraph?
    @ObservationIgnored private var asset: AVURLAsset?
    /// An undo opened by a drag, so the drag is one step.
    @ObservationIgnored private var openUndo: ClipEdits?

    init(item: ClipLibraryItem) {
        self.item = item
        var edits = item.clip.manifest?.edits ?? item.clip.take?.edits ?? ClipEdits()
        if item.kind == .recording, item.clip.take?.hasCamera == true, edits.camera == nil, edits.isEmpty {
            edits.camera = CameraPlacement()
        }
        self.edits = edits
        title = item.clip.manifest?.title ?? ""
        cursorLog = ClipRenderInputs.cursorLog(of: item)
    }

    var sourceURL: URL { ClipRenderInputs.sourceURL(of: item) }
    var cameraURL: URL? { ClipRenderInputs.cameraURL(of: item) }
    var assetsFolder: URL { ClipRenderInputs.assetsFolder(of: item) }

    /// The game's moments and who spoke, for the timeline's marks.
    var timeline: [ClipTimelineEvent] { item.clip.manifest?.timeline ?? [] }

    var outputDuration: Double { sequence.duration }
    /// The playhead's moment of the source.
    var sourceTime: Double { sequence.sourceTime(atOutput: currentTime) }

    /// The crop box in the picture's pixels, top-left origin.
    var cropRect: CGRect { edits.crop.rect(in: videoSize, position: edits.cropPosition) }

    /// Width over height of the canvas.
    var outputAspect: CGFloat { renderSize.height > 0 ? renderSize.width / renderSize.height : 16 / 9 }

    /// Where the picture sits on the canvas, in its 0…1 frame.
    var contentFrame: CGRect {
        let crop = cropRect
        return edits.canvas.layout(contentAspect: crop.height > 0 ? Double(crop.width / crop.height) : 16 / 9).content
    }

    var selectedOverlay: UUID? {
        get { if case .overlay(let id) = selection { id } else { nil } }
        set { selection = newValue.map { .overlay($0) } }
    }

    var selectedSegment: ClipSegment? {
        guard case .segment(let id) = selection else { return nil }
        return edits.resolvedSegments(in: sourceDuration).first { $0.id == id }
    }

    // MARK: Loading

    func load() async {
        let asset = AVURLAsset(url: sourceURL)
        self.asset = asset
        sourceDuration = (try? await asset.load(.duration).seconds) ?? 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            videoSize = (try? await track.load(.naturalSize)) ?? .zero
        }
        sequence = edits.sequence(in: sourceDuration)
        stems = await Self.stems(of: item, asset: asset)
        await rebuild()
        observeTime()
        isLoaded = true
        filmstrip = await Self.filmstrip(of: asset, duration: sourceDuration)
        waveform = await Self.waveform(of: asset)
    }

    /// The tracks a person can switch off: a clip's stems (never its mix,
    /// which is what the others are mixed into), a recording's two sounds.
    private static func stems(of item: ClipLibraryItem, asset: AVURLAsset) async -> [Stem] {
        let count = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        if let tracks = item.clip.manifest?.tracks, tracks.count == count, count > 1 {
            return tracks.enumerated().compactMap { index, track in
                switch track.role {
                case .mix: nil
                case .game: Stem(index: index, title: track.title, symbolName: "gamecontroller", isVoice: false)
                case .microphone: Stem(index: index, title: "You", symbolName: "mic", isVoice: true)
                case .voice: Stem(index: index, title: track.title, symbolName: "person.wave.2", isVoice: true)
                case .soundboard: Stem(index: index, title: "Soundboard", symbolName: "speaker.wave.3", isVoice: false)
                }
            }
        }
        if item.kind == .recording, let take = item.clip.take {
            var names: [(String, String, Bool)] = []
            if take.hasSystemAudio { names.append(("System Sound", "speaker.wave.2", false)) }
            if take.hasMicrophone { names.append(("Microphone", "mic", true)) }
            return (0..<count).map { index in
                let name = index < names.count ? names[index] : ("Sound \(index + 1)", "waveform", false)
                return Stem(index: index, title: name.0, symbolName: name.1, isVoice: name.2)
            }
        }
        return (0..<count).map {
            Stem(index: $0, title: count == 1 ? "Audio" : "Sound \($0 + 1)", symbolName: "waveform", isVoice: count == 1)
        }
    }

    /// Off the main actor: decoding sixty pictures is work for a background
    /// thread, and AVFoundation's async readers run on executors of their own.
    nonisolated private static func filmstrip(of asset: AVURLAsset, duration: Double) async -> [(time: Double, image: CGImage)] {
        guard duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let count = min(60, max(12, Int(duration * 2)))
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [(Double, CGImage)] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { images.append((result.requestedTime.seconds, image)) }
        }
        return images.sorted { $0.0 < $1.0 }
    }

    /// Peaks of the first audio track, 400 buckets along the source — off the
    /// main actor, as the filmstrip is.
    nonisolated private static func waveform(of asset: AVURLAsset) async -> [Float] {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return [] }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration > 0 else { return [] }
        // 8 kHz: the lowest rate the reader takes (4 kHz threw, 2026-10-21) —
        // plenty for a picture of loudness.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let provider = reader.outputProvider(for: output)
        guard (try? reader.start()) != nil else { return [] }
        let buckets = 400
        var peaks = [Float](repeating: 0, count: buckets)
        var index = 0
        let perBucket = max(1, Int(duration * 8_000) / buckets)
        while let sample = try? await provider.next() {
            sample.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                let length = CMBlockBufferGetDataLength(block)
                var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                values.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                for value in values {
                    let bucket = min(buckets - 1, index / perBucket)
                    peaks[bucket] = max(peaks[bucket], abs(value))
                    index += 1
                }
            }
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }

    // MARK: The graph

    /// The input the preview plays: the same as an export's, at a size the
    /// screen can show without encoding work it will never see.
    private func previewInput() async -> ClipRenderInput {
        var input = await ClipRenderInputs.input(for: item, edits: edits)
        let shortSide = min(videoSize.width, videoSize.height)
        if shortSide > 1_080 { input.shortSide = 1_080 }
        return input
    }

    /// Builds the composition again — after a cut, a speed, the crop, a
    /// sound switched or cleaned, the camera shown or hidden.
    private func rebuild() async {
        let input = await previewInput()
        guard let graph = try? await ClipRenderGraph.build(input) else { return }
        self.graph = graph
        renderSize = graph.renderSize
        let item = AVPlayerItem(asset: graph.composition)
        item.videoComposition = graph.videoComposition
        item.audioMix = graph.audioMix
        item.audioTimePitchAlgorithm = .spectral
        let time = min(currentTime, max(0, graph.duration - 0.05))
        let wasPlaying = isPlaying
        player.replaceCurrentItem(with: item)
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        if wasPlaying { player.play() }
    }

    /// Only the picture plan changed: swapped into the playing item, and the
    /// still frame drawn again when paused.
    private func redraw() {
        redrawTask?.cancel()
        redrawTask = Task { [weak self] in
            guard let self, let graph else { return }
            let canvasAspect = Double(graph.renderSize(for: edits.canvas).width / max(graph.renderSize(for: edits.canvas).height, 1))
            let composition = graph.replacing(
                canvas: edits.canvas, zooms: edits.zooms, blurs: edits.blurs, cursorStyle: edits.cursor,
                cameraPlacement: .some(edits.camera.map { ($0.x, $0.y, $0.diameter) }),
                overlays: ClipRenderInputs.overlays(for: item, edits: edits, canvasAspect: canvasAspect)
            )
            guard !Task.isCancelled else { return }
            renderSize = composition.renderSize
            player.currentItem?.videoComposition = composition
            if !isPlaying {
                await player.seek(
                    to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
        }
    }

    private func editsChanged(from old: ClipEdits) {
        sequence = edits.sequence(in: sourceDuration)
        let structural = edits.segments != old.segments || edits.start != old.start || edits.end != old.end
            || edits.crop != old.crop || edits.cropPosition != old.cropPosition
            || edits.mutedTracks != old.mutedTracks || edits.cleanedStems != old.cleanedStems
            || (edits.camera == nil) != (old.camera == nil)
        if structural {
            rebuildTask?.cancel()
            rebuildTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                await self?.rebuild()
            }
        } else {
            redraw()
        }
        if isAdjustingCrop, edits.crop != old.crop { refreshCropStill() }
    }

    // MARK: Playing

    private func observeTime() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    /// Discord's editor loops.
    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        isPlaying = player.rate != 0
        if isPlaying, seconds >= outputDuration - 0.03 { seek(to: 0) }
    }

    func togglePlay() {
        if player.rate != 0 {
            pause()
        } else {
            isAdjustingCrop = false
            if currentTime >= outputDuration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), outputDuration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isAdjustingCrop { refreshCropStill() }
    }

    /// One frame on or back — the arrow keys.
    func step(by frames: Int) {
        pause()
        player.currentItem?.step(byCount: frames)
    }

    private func refreshCropStill() {
        guard let asset else { return }
        let time = sourceTime
        Task {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            cropStill = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        }
    }

    // MARK: Undo

    /// Records the edits as they stand, as one undo step.
    private func recordUndo(_ previous: ClipEdits, named name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.edits
                model.edits = previous
                model.recordUndo(current, named: name)
            }
        }
        undoManager.setActionName(name)
    }

    /// A discrete change, undoable as one step.
    func change(_ name: String, _ body: (inout ClipEdits) -> Void) {
        let previous = edits
        var next = edits
        body(&next)
        guard next != previous else { return }
        edits = next
        recordUndo(previous, named: name)
    }

    /// The start of a drag: everything until `endChange` is one step.
    func beginChange() {
        if openUndo == nil { openUndo = edits }
    }

    func endChange(_ name: String) {
        guard let previous = openUndo else { return }
        openUndo = nil
        if previous != edits { recordUndo(previous, named: name) }
    }

    // MARK: Cuts and speed

    /// S / ⌘B: the segment under the playhead cut in two there.
    func splitAtPlayhead() {
        var newID: UUID?
        change("Split") { newID = $0.split(atOutput: currentTime, duration: sourceDuration) }
        if let newID { selection = .segment(newID) }
    }

    func deleteSelectedSegment() {
        guard case .segment(let id) = selection else { return }
        change("Delete Segment") { $0.removeSegment(id, duration: sourceDuration) }
        selection = nil
    }

    func setSpeed(_ speed: Double) {
        guard case .segment(let id) = selection else { return }
        change("Change Speed") { $0.setSpeed(speed, of: id, duration: sourceDuration) }
    }

    /// I and O: the kept stretch under the playhead starts or ends here.
    func setStartHere() {
        let segments = edits.resolvedSegments(in: sourceDuration)
        guard let index = sequence.index(atOutput: currentTime) else { return }
        let id = segments[index].id
        let source = sourceTime
        change("Set Start") { $0.trimSegment(id, start: source, duration: sourceDuration) }
    }

    func setEndHere() {
        let segments = edits.resolvedSegments(in: sourceDuration)
        guard let index = sequence.index(atOutput: currentTime) else { return }
        let id = segments[index].id
        let source = sourceTime
        change("Set End") { $0.trimSegment(id, end: source, duration: sourceDuration) }
    }

    // MARK: Words and pictures

    func addText() {
        let start = sourceTime
        let text = TextOverlay(text: "Add text here", start: start, end: min(sourceDuration, start + 3))
        change("Add Text") { $0.texts.append(text) }
        selection = .overlay(text.id)
    }

    /// Discord's image overlay: PNG, JPEG or WebP, copied beside the clip.
    func addImage(from url: URL) throws {
        let type = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp"].contains(type) else { throw OverlayFailure.unsupported }
        guard NSImage(contentsOf: url) != nil else { throw OverlayFailure.unreadable }
        try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(type)"
        try FileManager.default.copyItem(at: url, to: assetsFolder.appendingPathComponent(name))
        let start = sourceTime
        let image = ImageOverlay(fileName: name, start: start, end: min(sourceDuration, start + 3))
        change("Add Image") { $0.images.append(image) }
        selection = .overlay(image.id)
    }

    enum OverlayFailure: LocalizedError {
        case unsupported, unreadable

        var errorDescription: String? {
            switch self {
            // Discord's own words (`j3AKJQ`, `piRNeN`).
            case .unsupported: "That file isn't a supported image. Try a PNG, JPEG, or WebP."
            case .unreadable: "Couldn't read that image."
            }
        }
    }

    func removeOverlay(_ id: UUID) {
        change("Remove") {
            $0.texts.removeAll { $0.id == id }
            $0.images.removeAll { $0.id == id }
        }
        if selectedOverlay == id { selection = nil }
    }

    /// ⌫ on whatever is selected.
    func deleteSelection() {
        switch selection {
        case .segment: deleteSelectedSegment()
        case .overlay(let id): removeOverlay(id)
        case .zoom(let id):
            change("Remove Zoom") { $0.zooms.removeAll { $0.id == id } }
            selection = nil
        case .blur(let id):
            change("Remove Blur") { $0.blurs.removeAll { $0.id == id } }
            selection = nil
        case .caption(let id):
            change("Remove Caption") { $0.captions.removeAll { $0.id == id } }
            selection = nil
        case nil:
            break
        }
    }

    // MARK: Zooms, blurs, the cursor

    func addZoom() {
        let start = sourceTime
        let point = cursorLog?.position(at: start + 1, smoothing: 0.5)
        let zoom = ZoomBlock(
            start: start, end: min(sourceDuration, start + 2.5), scale: 2,
            x: Double(point?.x ?? 0.5), y: Double(point?.y ?? 0.5)
        )
        change("Add Zoom") { $0.zooms.append(zoom) }
        selection = .zoom(zoom.id)
    }

    /// Smart Zoom: one zoom on each run of clicks, replacing the last
    /// suggestions and keeping the hand-made ones.
    func suggestZooms() {
        guard let cursorLog else { return }
        let suggested = SmartZoom.suggestions(from: cursorLog, duration: sourceDuration)
        change("Suggest Zooms") { $0.zooms = $0.zooms.filter { !$0.isSuggested } + suggested }
    }

    var canSuggestZooms: Bool { cursorLog.map { !$0.clicks.isEmpty } ?? false }

    func addBlur() {
        let start = sourceTime
        let blur = BlurRegion(start: start, end: min(sourceDuration, start + 3))
        change("Add Blur") { $0.blurs.append(blur) }
        selection = .blur(blur.id)
    }

    // MARK: Captions

    func transcribe(stem: Int) {
        guard captionState == .idle || { if case .failed = captionState { true } else { false } }() else { return }
        captionState = .working(.preparing)
        let source = sourceURL
        Task {
            do {
                let words = try await CaptionTranscriber.transcribe(source: source, track: stem) { [weak self] stage in
                    self?.captionState = .working(stage)
                }
                let lines = Caption.lines(from: words)
                change("Captions") {
                    $0.captions = lines
                    $0.showsCaptions = true
                }
                captionState = .idle
            } catch {
                captionState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Voice clean-up

    func setCleanUp(_ on: Bool, stem: Int) {
        guard on else {
            change("Voice Clean-Up") { $0.cleanedStems.remove(stem) }
            return
        }
        let destination = ClipRenderInputs.cleanedStemURL(of: item, stem: stem)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            change("Voice Clean-Up") { $0.cleanedStems.insert(stem) }
            return
        }
        cleaningStems.insert(stem)
        cleanUpFailure = nil
        let source = sourceURL
        Task {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await VoiceCleanUp.process(source: source, track: stem, to: destination)
                cleaningStems.remove(stem)
                change("Voice Clean-Up") { $0.cleanedStems.insert(stem) }
            } catch {
                cleaningStems.remove(stem)
                cleanUpFailure = error.localizedDescription
            }
        }
    }

    // MARK: Keeping it

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes the edits — and the title — into the clip's sidecar, or a
    /// recording's take.json.
    func save() {
        saveTask?.cancel()
        let stored = edits.isEmpty ? nil : edits
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.kind == .recording, var take = item.clip.take {
            take.edits = stored
            ClipLibrary.writeTake(take, in: item.url)
        } else if item.kind == .clip {
            var manifest = item.clip.manifest ?? ClipManifest(createdAt: item.clip.created, duration: sourceDuration)
            manifest.edits = stored
            manifest.title = named.isEmpty ? nil : named
            ClipLibrary.writeManifest(manifest, for: item.url)
        }
    }

    func tearDown() {
        save()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Exporting

    /// The edited clip as a file — the Export sheet and Share both use it.
    func export(
        to destination: URL, settings: ClipExportSettings, maxBytes: Int?, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        save()
        return try await ClipExport.export(
            item, edits: edits, settings: settings, maxShortSide: nil, to: destination, maxBytes: maxBytes, progress: progress
        )
    }
}

// MARK: - Exporting from anywhere

/// An item exported with its saved edits — the editor's Export and Share, and
/// the library's Share of several at once, go through here.
enum ClipExport {
    /// - Parameters:
    ///   - settings: the Export sheet's choices; Share's default is the
    ///     picture's own size, capped at 1080.
    ///   - maxBytes: the upload limit to fit under, for a share.
    static func export(
        _ item: ClipLibraryItem, edits: ClipEdits? = nil, settings: ClipExportSettings = ClipExportSettings(resolution: .original),
        maxShortSide: Int? = 1_080, to destination: URL, maxBytes: Int?, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let edits = edits ?? item.clip.manifest?.edits ?? item.clip.take?.edits ?? ClipEdits()
        let input = await ClipRenderInputs.input(for: item, edits: edits, settings: settings)
        return try await ClipExporter.export(.init(
            input: input, format: settings.format, maxBytes: maxBytes, maxShortSide: maxShortSide, destination: destination
        ), progress: progress)
    }

    /// What a shared clip says about itself — the manifest's people, game and
    /// timeline, moved through the edit's cuts and speeds.
    static func upload(for item: ClipLibraryItem, duration: Double?) -> ClipUpload? {
        guard item.kind == .clip else { return nil }
        let manifest = item.clip.manifest
        let edits = manifest?.edits ?? ClipEdits()
        let sequence = edits.sequence(in: manifest?.duration ?? duration ?? 0)
        return ClipUpload(
            title: manifest?.title ?? item.title,
            applicationID: manifest?.game?.applicationID,
            createdAt: manifest?.createdAt ?? item.clip.created,
            participantIDs: manifest?.participants.map(\.userID) ?? [],
            timeline: manifest?.timeline(through: sequence) ?? [],
            durationSeconds: duration ?? sequence.duration,
            // One moment from several people: the id ties the views together
            // in the player (Phase 7.3); the moment it was clipped is the
            // clock they share.
            remoteID: manifest?.remoteClipID,
            syncTimestamp: manifest?.remoteClipID == nil ? nil : manifest?.createdAt
        )
    }
}
