import Foundation
import Synchronization

// MARK: - A ring between a decoder and a render callback
//
// One writer, one reader, and no lock on either side. That is not premature:
// the reader is CoreAudio's render thread, which has a hard deadline measured in
// milliseconds and may not block, allocate or take a lock that a lower-priority
// thread can hold. A `Mutex` there is a priority inversion and it presents as a
// click, which is the one artefact nobody can explain from a log.
//
// The invariant that makes it safe with two plain atomics: **the writer only
// ever advances `written` and the reader only ever advances `read`**, both
// monotonically, and each side derives everything it needs from its own index
// plus one acquire-load of the other's. Neither index is ever written by both.

public final class AudioRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    /// - Parameter capacity: in samples, and it must be a power of two so the
    ///   wrap is a mask rather than a division. A division in a render callback
    ///   is not fatal but it is a hundred cycles nobody has to spend.
    public init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Samples waiting to be played.
    public var count: Int {
        written.load(ordering: .acquiring) - read.load(ordering: .acquiring)
    }

    public var available: Int { capacity - count }

    /// Writer side. Drops the whole block rather than a part of it when there
    /// is no room: half a frame in a stereo ring swaps the channels for every
    /// sample after it, permanently.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count wanted: Int) -> Bool {
        let head = written.load(ordering: .relaxed)
        let tail = read.load(ordering: .acquiring)
        guard capacity - (head - tail) >= wanted else { return false }

        let offset = head & (capacity - 1)
        let firstRun = min(wanted, capacity - offset)
        storage.advanced(by: offset).update(from: samples, count: firstRun)
        if firstRun < wanted {
            storage.update(from: samples.advanced(by: firstRun), count: wanted - firstRun)
        }
        written.store(head + wanted, ordering: .releasing)
        return true
    }

    /// Reader side. Fills the whole request, padding with silence when the
    /// writer has fallen behind — a render callback must always produce
    /// something, and the alternative to silence is whatever was in the buffer
    /// last time, which is a buzz.
    public func read(into destination: UnsafeMutablePointer<Float>, count wanted: Int) -> Int {
        let tail = read.load(ordering: .relaxed)
        let head = written.load(ordering: .acquiring)
        let ready = min(wanted, head - tail)
        guard ready > 0 else {
            destination.update(repeating: 0, count: wanted)
            return 0
        }

        let offset = tail & (capacity - 1)
        let firstRun = min(ready, capacity - offset)
        destination.update(from: storage.advanced(by: offset), count: firstRun)
        if firstRun < ready {
            destination.advanced(by: firstRun)
                .update(from: storage, count: ready - firstRun)
        }
        if ready < wanted {
            destination.advanced(by: ready).update(repeating: 0, count: wanted - ready)
        }
        read.store(tail + ready, ordering: .releasing)
        return ready
    }

    /// Throws away everything queued. For a device change, where the samples in
    /// flight belong to a clock that no longer exists.
    public func drain() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}
