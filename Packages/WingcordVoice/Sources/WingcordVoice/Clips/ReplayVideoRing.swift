import CoreMedia
import Foundation
import OSLog
import Synchronization

// MARK: - The last N seconds of picture, encoded
//
// docs/CLIPS-PRESENCE.md, D10 and Phase 0.4. The encoder's output is kept as
// it came out — compressed samples, never pictures — and trimmed **a whole
// group of pictures at a time**, so the oldest thing kept is always a
// keyframe and a save can start anywhere without re-encoding. Measured in
// Phase 0.4: HEVC at 1080p60 is 180–220 MB for two minutes, so the samples sit
// in memory up to a budget and the oldest are moved to a cache file past it.

/// A format description, carried across threads. `@unchecked` because Core
/// Media's descriptions are immutable once made and only ever read.
struct FormatBox: @unchecked Sendable {
    let formatDescription: CMFormatDescription
}

public final class ReplayVideoRing: Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")

    /// One encoded picture.
    struct Frame: Sendable {
        var sequence: UInt64
        var presentation: CMTime
        var decode: CMTime
        var duration: CMTime
        var isKeyframe: Bool
        var format: FormatBox
        var byteCount: Int
        var storage: Storage
    }

    enum Storage: Sendable {
        case memory(Data)
        /// Moved to the cache file: where its bytes start in segment `segment`.
        case spilled(segment: Int, offset: UInt64)
    }

    private struct State {
        var frames: [Frame] = []
        var head = 0
        var sequence: UInt64 = 0
        var memoryBytes = 0
        /// Frames being written out right now — kept in memory until the
        /// write lands, so a save in the meantime still has them.
        var spilling = false
    }

    private let state = Mutex(State())
    private let window: Mutex<Double>
    /// The most picture held in memory, in bytes.
    let memoryBudget: Int
    private let spill: SpillFiles?
    private let spillQueue = DispatchQueue(label: "dev.wingcord.clips.spill", qos: .utility)

    /// - Parameters:
    ///   - window: seconds kept behind the newest picture.
    ///   - memoryBudget: bytes held in memory before the oldest go to disk.
    ///   - spillDirectory: where they go; nil keeps everything in memory and
    ///     trims to the budget instead.
    public init(window: Double, memoryBudget: Int, spillDirectory: URL?) {
        self.window = Mutex(window)
        self.memoryBudget = memoryBudget
        spill = spillDirectory.flatMap { SpillFiles(directory: $0) }
    }

    public func setWindow(_ seconds: Double) {
        window.withLock { $0 = seconds }
    }

    /// Everything kept — for the settings pane's line about what clips cost.
    public var memoryBytes: Int { state.withLock { $0.memoryBytes } }

    public var duration: Double {
        state.withLock { state in
            guard state.head < state.frames.count, let last = state.frames.last else { return 0 }
            return (last.presentation - state.frames[state.head].presentation).seconds
        }
    }

    /// Forgets every picture — the game changed, or clips were turned off.
    public func reset() {
        state.withLock { state in
            state.frames = []
            state.head = 0
            state.memoryBytes = 0
        }
        spill?.removeAll()
    }

    // MARK: Writing

    /// Keeps one sample the encoder produced. Runs on VideoToolbox's thread.
    func append(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let data = Self.bytes(of: sample)
        else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let decode = CMSampleBufferGetDecodeTimeStamp(sample)
        let frameDuration = CMSampleBufferGetDuration(sample)
        let isKeyframe = Self.isKeyframe(sample)
        append(
            data, format: FormatBox(formatDescription: format), presentation: presentation,
            decode: decode.isValid ? decode : presentation, duration: frameDuration, isKeyframe: isKeyframe
        )
    }

    func append(
        _ data: Data, format: FormatBox, presentation: CMTime, decode: CMTime, duration: CMTime, isKeyframe: Bool
    ) {
        let window = self.window.withLock { $0 }
        var dropped: [Frame] = []
        let needsSpill = state.withLock { state -> Bool in
            // A stream must open on a keyframe, or nothing before the first
            // one could ever be decoded.
            if state.head >= state.frames.count, !isKeyframe { return false }
            state.sequence &+= 1
            state.frames.append(Frame(
                sequence: state.sequence, presentation: presentation, decode: decode, duration: duration,
                isKeyframe: isKeyframe, format: format, byteCount: data.count, storage: .memory(data)
            ))
            state.memoryBytes += data.count

            // **Whole groups only.** The cut lands on the newest keyframe that
            // is still at least `window` old, so what remains starts on a
            // keyframe and covers the whole window.
            let cutoff = presentation.seconds - window
            var cut = state.head
            var index = state.head
            while index < state.frames.count, state.frames[index].presentation.seconds <= cutoff {
                if state.frames[index].isKeyframe { cut = index }
                index += 1
            }
            if cut > state.head {
                dropped = Array(state.frames[state.head..<cut])
                for frame in dropped {
                    if case .memory = frame.storage { state.memoryBytes -= frame.byteCount }
                }
                state.head = cut
            }
            if state.head > 1_024 {
                state.frames.removeFirst(state.head)
                state.head = 0
            }

            guard state.memoryBytes > memoryBudget else { return false }
            if spill == nil {
                // No disk to go to: the window shortens to what fits, a whole
                // group at a time, rather than the app growing without bound.
                Self.trimToBudget(&state, budget: memoryBudget)
                return false
            }
            guard !state.spilling else { return false }
            state.spilling = true
            return true
        }
        if !dropped.isEmpty { spill?.forget(through: dropped) }
        if needsSpill { scheduleSpill() }
    }

    private static func trimToBudget(_ state: inout State, budget: Int) {
        while state.memoryBytes > budget, state.head + 1 < state.frames.count {
            guard let next = state.frames[(state.head + 1)...].firstIndex(where: \.isKeyframe) else { return }
            for frame in state.frames[state.head..<next] { state.memoryBytes -= frame.byteCount }
            state.head = next
        }
    }

    /// Moves the oldest pictures held in memory to the cache file until the
    /// rest fit the budget — off the encoder's thread.
    private func scheduleSpill() {
        spillQueue.async { [self] in
            spillOnce()
            // Pictures kept arriving while that ran; go again until they fit.
            let again = state.withLock { state -> Bool in
                guard state.memoryBytes > memoryBudget else {
                    state.spilling = false
                    return false
                }
                return true
            }
            if again { scheduleSpill() }
        }
    }

    private func spillOnce() {
        guard let spill else { return }
        // Taken in one read; written outside the lock.
        let batch: [Frame] = state.withLock { state in
            var excess = state.memoryBytes - memoryBudget / 2
            var taken: [Frame] = []
            for frame in state.frames[state.head...] where excess > 0 {
                guard case .memory = frame.storage else { continue }
                taken.append(frame)
                excess -= frame.byteCount
            }
            return taken
        }
        var moved: [UInt64: Storage] = [:]
        for frame in batch {
            guard case .memory(let data) = frame.storage,
                  let location = spill.write(data, presentation: frame.presentation.seconds)
            else { continue }
            moved[frame.sequence] = .spilled(segment: location.segment, offset: location.offset)
        }
        guard !moved.isEmpty else { return }
        state.withLock { state in
            for index in state.head..<state.frames.count {
                guard let storage = moved[state.frames[index].sequence],
                      case .memory = state.frames[index].storage
                else { continue }
                state.frames[index].storage = storage
                state.memoryBytes -= state.frames[index].byteCount
            }
        }
    }

    // MARK: Reading

    /// The pictures for a clip of `seconds` ending at `end` (the newest when
    /// nil): from the newest keyframe at or before the start, so the clip is
    /// never shorter than asked while the ring holds that much.
    ///
    /// **One format only.** A window resized mid-buffer changes the encoder's
    /// picture size, and a track is one size; the clip then starts at the
    /// first keyframe of the newest.
    func frames(lasting seconds: Double, endingAt end: Double? = nil) -> [Frame] {
        state.withLock { state -> [Frame] in
            guard state.head < state.frames.count else { return [] }
            var kept = Array(state.frames[state.head...])
            if let end { kept = kept.filter { $0.presentation.seconds <= end } }
            guard let newest = kept.last else { return [] }
            if let change = kept.lastIndex(where: { !CMFormatDescriptionEqual($0.format.formatDescription, otherFormatDescription: newest.format.formatDescription) }) {
                kept = Array(kept[(change + 1)...])
                guard let first = kept.firstIndex(where: \.isKeyframe) else { return [] }
                kept = Array(kept[first...])
            }
            let target = newest.presentation.seconds - seconds
            let start = kept.lastIndex { $0.isKeyframe && $0.presentation.seconds <= target }
                ?? kept.firstIndex(where: \.isKeyframe)
            guard let start else { return [] }
            return Array(kept[start...])
        }
    }

    /// A frame's bytes, from memory or the cache file.
    func bytes(of frame: Frame) -> Data? {
        switch frame.storage {
        case .memory(let data): data
        case .spilled(let segment, let offset): spill?.read(segment: segment, offset: offset, count: frame.byteCount)
        }
    }

    // MARK: Samples

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first
        else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// The sample's bytes, contiguous.
    static func bytes(of sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    /// A kept frame as a sample buffer again, for the writer.
    func sampleBuffer(for frame: Frame) -> CMSampleBuffer? {
        guard let data = bytes(of: frame) else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: frame.duration, presentationTimeStamp: frame.presentation, decodeTimeStamp: frame.decode
        )
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: frame.format.formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if !frame.isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0
        {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

// MARK: - The cache file

/// Append-only segments of spilled picture, one per stretch of time, removed
/// as the ring moves past them. Plain files in Caches: nothing here survives a
/// relaunch, and nothing needs to.
private final class SpillFiles: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")
    /// Seconds of picture per segment: small enough that a trim frees disk
    /// promptly, big enough that a session makes a few dozen files, not
    /// thousands.
    private static let segmentSpan = 10.0

    private struct Segment {
        var index: Int
        var url: URL
        var handle: FileHandle
        var length: UInt64
        var newest: Double
    }

    private let directory: URL
    private let lock = NSLock()
    private var segments: [Segment] = []
    private var nextIndex = 0
    private var segmentStart: Double?

    init?(directory: URL) {
        self.directory = directory
        do {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.log.warning("clips: no cache folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    deinit { removeAll() }

    func write(_ data: Data, presentation: Double) -> (segment: Int, offset: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        if segments.isEmpty || presentation - (segmentStart ?? presentation) > Self.segmentSpan {
            let url = directory.appendingPathComponent("segment-\(nextIndex).bin")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forUpdating: url)
            else { return nil }
            segments.append(Segment(index: nextIndex, url: url, handle: handle, length: 0, newest: presentation))
            segmentStart = presentation
            nextIndex += 1
        }
        let last = segments.count - 1
        let offset = segments[last].length
        do {
            try segments[last].handle.seekToEnd()
            try segments[last].handle.write(contentsOf: data)
        } catch {
            return nil
        }
        segments[last].length += UInt64(data.count)
        segments[last].newest = max(segments[last].newest, presentation)
        return (segments[last].index, offset)
    }

    func read(segment: Int, offset: UInt64, count: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let found = segments.first(where: { $0.index == segment }) else { return nil }
        do {
            try found.handle.seek(toOffset: offset)
            return try found.handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    /// Removes every segment whose pictures have all left the ring.
    func forget(through dropped: [ReplayVideoRing.Frame]) {
        guard let oldestKept = dropped.last?.presentation.seconds else { return }
        lock.lock()
        defer { lock.unlock() }
        while let first = segments.first, first.newest <= oldestKept, segments.count > 1 {
            try? first.handle.close()
            try? FileManager.default.removeItem(at: first.url)
            segments.removeFirst()
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for segment in segments {
            try? segment.handle.close()
            try? FileManager.default.removeItem(at: segment.url)
        }
        segments = []
        segmentStart = nil
    }
}
