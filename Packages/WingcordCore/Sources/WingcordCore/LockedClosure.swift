/// A closure to keep in a `Mutex`: `Mutex<LockedClosure<@Sendable (String) -> Void>?>`,
/// read with `slot.withLock { $0 }?.call(…)`.
///
/// **Never `Mutex<(… -> …)?>` itself.** Reading a closure kept bare in a mutex
/// with `withLock { $0 }` wraps the stored closure in two more conversion
/// thunks and writes them back — on every read, optimised or not. A closure
/// read once per log line, audio buffer or captured frame is soon thousands
/// of frames deep, and calling it overflows the thread's stack: the three
/// crashes of 13 November 2026 were the session log's mirror, read per line,
/// overflowing a cooperative thread an hour or so into a run. A struct
/// holding the closure is copied out whole and never rewrapped (measured:
/// three frames deep after 11,001 reads, against 20,003 after 10,000 bare).
public struct LockedClosure<Function: Sendable>: Sendable {
    public let call: Function

    public init(_ call: Function) {
        self.call = call
    }
}
