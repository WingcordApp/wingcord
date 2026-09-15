import Darwin
import Foundation

// MARK: - Reading another process's command line
//
// **`NSRunningApplication` does not carry arguments**, and the arguments are
// where a translated Windows game keeps its identity: a title under Whisky or
// Game Porting Toolkit is `wine64-preloader` by every name AppKit knows, with
// `…/Game.exe` sitting in `argv`. Matching without this finds the translation
// layer and never the game.
//
// `sysctl(KERN_PROCARGS2)` is the supported way to read them, it is what `ps`
// itself uses, and it needs **no entitlement and no permission prompt** for a
// process owned by the same user. It fails cleanly for anything else — a root
// daemon, another user's process — and a failure here is an empty argument list
// rather than an error, because a game we cannot inspect is simply a game we do
// not detect.

enum ProcessInspector {

    /// The command line of `pid`, argv[0] included.
    ///
    /// Empty when the process is gone, owned by somebody else, or refuses to be
    /// read. Never throws: every caller's fallback is "no match".
    nonisolated static func arguments(of pid: pid_t) -> [String] {
        // The buffer size is asked for rather than assumed. `ARG_MAX` is a
        // megabyte on macOS and allocating it per process — for every app the
        // reader has open — is a megabyte of churn on every launch notification.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes { raw -> Bool in
            var length = size
            return sysctl(&mib, 3, raw.baseAddress, &length, nil, 0) == 0
        }
        guard read else { return [] }
        return parse(buffer)
    }

    /// Walks the `KERN_PROCARGS2` layout.
    ///
    /// ```
    /// int32 argc
    /// char  exec_path[]   NUL-terminated
    /// char  padding[]     zero or more NULs, for alignment
    /// char  argv[0][] … argv[argc-1][]
    /// char  envp[][]      ignored
    /// ```
    ///
    /// **The padding is the part that is easy to get wrong.** The executable
    /// path is followed by an unspecified run of NULs before `argv[0]` begins,
    /// so a parser that takes the next string after `exec_path` reads an empty
    /// one and every argument after it lands one slot early.
    ///
    /// `internal` rather than `private` so the layout can be tested without a
    /// live process — see `ProcessInspectorTests`.
    nonisolated static func parse(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        // Skip the executable path.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        // Skip the padding. See the note above.
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        while arguments.count < Int(argc), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            if let text = String(bytes: buffer[start..<index], encoding: .utf8) {
                arguments.append(text)
            }
            index += 1
        }
        return arguments
    }
}
