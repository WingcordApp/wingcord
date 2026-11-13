import Darwin
import Foundation
import Synchronization

/// One ring of the log: a file of fixed size, mapped into memory and written as
/// a circle (docs/BUG-REPORTING.md D18).
///
/// **Mapped, so a line is a memory copy and survives a crash with no flush.**
/// The pages are the file's own, shared with the kernel's cache of it: when the
/// process dies — a crash, a force quit, a debugger stop — what was copied in is
/// already the file's, and the kernel writes it out on its own schedule. Only a
/// kernel panic or a power loss can take the last few seconds. Apple's unified
/// log was the alternative and was turned down: it cannot be read back after a
/// crash without an administrator's rights, and a tester has none to give.
///
/// **A circle, so it never grows.** The cursor counts every byte ever written;
/// the write position is the cursor modulo the capacity. Once the cursor passes
/// the capacity, the oldest bytes are overwritten in place, and a read starts at
/// the first whole line after the write position.
///
/// The file's first 64 bytes are a header — a magic number, the capacity, the
/// cursor — and the cursor is stored after each copy, as one aligned 8-byte
/// store. A crash between the copy and the store loses that one line and
/// nothing else.
public final class LogRing: Sendable {
    /// Why a ring could not be opened on disk.
    public enum OpenError: Error, Equatable {
        /// Another process holds the file — a second copy of the app with the
        /// same bundle identifier. Two writers with two cursors would cut each
        /// other's lines in half, so the second one takes another file.
        case busy
        case system(Int32)
    }

    static let headerSize = 64
    /// "WCLOGv01", read as a little-endian integer.
    static let magic: UInt64 = 0x3130_7647_4F4C_4357
    private static let magicOffset = 0
    private static let capacityOffset = 8
    private static let cursorOffset = 16

    /// The bytes a ring holds, not counting its header.
    public let capacity: Int
    /// The file, or nil for a ring kept in memory only.
    public let url: URL?

    private struct Mapping: @unchecked Sendable {
        var base: UnsafeMutableRawPointer
        var length: Int
        var descriptor: Int32
    }

    private let mapping: Mutex<Mapping>

    /// Opens (or creates) a ring file and takes it for this process.
    ///
    /// A file of the wrong size or with a header that does not read is started
    /// over rather than trusted: a cursor read out of a torn header would send
    /// the next copy outside the mapping.
    public init(url: URL, capacity: Int) throws(OpenError) {
        precondition(capacity > 0)
        let path = url.path(percentEncoded: false)
        let descriptor = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw .system(errno) }
        // **An advisory lock, held for the life of the process.** Released by
        // the kernel when the process ends however it ends, so a crashed copy
        // never leaves its file locked.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw code == EWOULDBLOCK ? .busy : .system(code)
        }
        let length = Self.headerSize + capacity
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw .system(code)
        }
        let wasSized = Int(status.st_size) == length
        if !wasSized, ftruncate(descriptor, off_t(length)) != 0 {
            let code = errno
            close(descriptor)
            throw .system(code)
        }
        guard let base = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              base != MAP_FAILED
        else {
            let code = errno
            close(descriptor)
            throw .system(code)
        }
        self.capacity = capacity
        self.url = url
        mapping = Mutex(Mapping(base: base, length: length, descriptor: descriptor))
        if !wasSized || !Self.headerIsValid(base, capacity: capacity) {
            Self.format(base, length: length, capacity: capacity)
        }
    }

    /// A ring in memory only — for when every file is taken, and for tests.
    /// Nothing in it outlives the process.
    public init(inMemoryCapacity capacity: Int) {
        precondition(capacity > 0)
        let length = Self.headerSize + capacity
        let base = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        precondition(base != nil && base != MAP_FAILED, "an anonymous mapping of \(length) bytes failed")
        self.capacity = capacity
        url = nil
        mapping = Mutex(Mapping(base: base!, length: length, descriptor: -1))
        Self.format(base!, length: length, capacity: capacity)
    }

    deinit {
        mapping.withLock { mapping in
            munmap(mapping.base, mapping.length)
            if mapping.descriptor >= 0 {
                flock(mapping.descriptor, LOCK_UN)
                close(mapping.descriptor)
            }
        }
    }

    // MARK: Writing

    /// Copies one record in. A record longer than the ring keeps its tail.
    public func append(_ bytes: UnsafeRawBufferPointer) {
        guard let source = bytes.baseAddress, bytes.count > 0 else { return }
        mapping.withLock { mapping in
            let data = mapping.base + Self.headerSize
            let cursorPointer = (mapping.base + Self.cursorOffset).assumingMemoryBound(to: UInt64.self)
            var cursor = cursorPointer.pointee
            var start = source
            var count = bytes.count
            if count > capacity {
                start += count - capacity
                cursor &+= UInt64(count - capacity)
                count = capacity
            }
            let position = Int(cursor % UInt64(capacity))
            let first = min(count, capacity - position)
            memcpy(data + position, start, first)
            if count > first {
                memcpy(data, start + first, count - first)
            }
            cursorPointer.pointee = cursor &+ UInt64(count)
        }
    }

    public func append(_ text: String) {
        var text = text
        text.withUTF8 { append(UnsafeRawBufferPointer($0)) }
    }

    /// Empties the ring. The file stays, the same size.
    public func clear() {
        mapping.withLock { mapping in
            Self.format(mapping.base, length: mapping.length, capacity: capacity)
        }
    }

    // MARK: Reading

    /// Everything the ring holds, oldest first, as whole lines.
    ///
    /// Copied out under the lock in one pass — at most the ring's capacity — and
    /// trimmed outside it. Once the ring has wrapped, the bytes at the write
    /// position are the tail of a line whose head was overwritten, so the read
    /// starts after the first newline it finds there.
    public func contents() -> Data {
        let (bytes, hasWrapped) = mapping.withLock { mapping -> (Data, Bool) in
            let data = mapping.base + Self.headerSize
            let cursor = (mapping.base + Self.cursorOffset).assumingMemoryBound(to: UInt64.self).pointee
            if cursor <= UInt64(capacity) {
                return (Data(bytes: data, count: Int(cursor)), false)
            }
            let position = Int(cursor % UInt64(capacity))
            var copy = Data(capacity: capacity)
            copy.append(UnsafeBufferPointer(
                start: (data + position).assumingMemoryBound(to: UInt8.self),
                count: capacity - position
            ))
            copy.append(UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: position
            ))
            return (copy, true)
        }
        guard hasWrapped else { return bytes }
        guard let newline = bytes.firstIndex(of: 0x0A) else { return Data() }
        return bytes.subdata(in: bytes.index(after: newline)..<bytes.endIndex)
    }

    /// How many bytes have ever been written — what a test reads to know the
    /// ring wrapped.
    public var bytesWritten: UInt64 {
        mapping.withLock { mapping in
            (mapping.base + Self.cursorOffset).assumingMemoryBound(to: UInt64.self).pointee
        }
    }

    // MARK: The header

    private static func headerIsValid(_ base: UnsafeMutableRawPointer, capacity: Int) -> Bool {
        let magic = (base + magicOffset).assumingMemoryBound(to: UInt64.self).pointee
        let stored = (base + capacityOffset).assumingMemoryBound(to: UInt64.self).pointee
        return magic == Self.magic && stored == UInt64(capacity)
    }

    private static func format(_ base: UnsafeMutableRawPointer, length: Int, capacity: Int) {
        memset(base, 0, length)
        (base + magicOffset).assumingMemoryBound(to: UInt64.self).pointee = magic
        (base + capacityOffset).assumingMemoryBound(to: UInt64.self).pointee = UInt64(capacity)
        (base + cursorOffset).assumingMemoryBound(to: UInt64.self).pointee = 0
    }
}
