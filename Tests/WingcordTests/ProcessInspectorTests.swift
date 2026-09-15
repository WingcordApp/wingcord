import Foundation
import Testing
@testable import Wingcord

/// The `KERN_PROCARGS2` buffer layout.
///
/// Tested against hand-built buffers rather than a live process: the layout is
/// the thing that is easy to get wrong, and a test that launched something
/// would prove the syscall works without proving the walk does.
@Suite("Process arguments")
struct ProcessInspectorTests {

    /// Builds the exact shape the kernel returns.
    ///
    /// ```
    /// int32 argc | exec_path \0 | padding \0… | argv[0] \0 … | envp \0…
    /// ```
    private func buffer(
        argc: Int32,
        executable: String,
        padding: Int,
        arguments: [String],
        environment: [String] = []
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: argc) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(executable.utf8))
        bytes.append(0)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for argument in arguments {
            bytes.append(contentsOf: Array(argument.utf8))
            bytes.append(0)
        }
        for entry in environment {
            bytes.append(contentsOf: Array(entry.utf8))
            bytes.append(0)
        }
        return bytes
    }

    @Test("The padding after exec_path is skipped, however long it is")
    func paddingIsSkipped() {
        // The trap. A parser that takes the next string after `exec_path` reads
        // an empty one and lands every argument one slot early — so argv[0]
        // arrives as "" and the game's `.exe` is never seen at all.
        for padding in [0, 1, 3, 7, 15] {
            let bytes = buffer(
                argc: 2,
                executable: "/opt/wine/bin/wine64",
                padding: padding,
                arguments: ["wine64", "C:\\Games\\Hades.exe"]
            )
            #expect(
                ProcessInspector.parse(bytes) == ["wine64", "C:\\Games\\Hades.exe"],
                "padding of \(padding) bytes"
            )
        }
    }

    @Test("Exactly argc arguments come back, and the environment is not one of them")
    func stopsAtArgc() {
        let bytes = buffer(
            argc: 2,
            executable: "/usr/bin/thing",
            padding: 4,
            arguments: ["thing", "--flag"],
            environment: ["PATH=/usr/bin", "HOME=/Users/a"]
        )
        // Reading past argc turns every environment variable into an argument,
        // and `PATH=…` contains paths that would match the database.
        #expect(ProcessInspector.parse(bytes) == ["thing", "--flag"])
    }

    @Test("A truncated buffer yields what it can rather than trapping")
    func truncated() {
        var bytes = buffer(
            argc: 3, executable: "/usr/bin/thing", padding: 2, arguments: ["thing", "--flag", "x"]
        )
        bytes.removeLast(4)
        // The contract is "no match", never a crash: this runs for every
        // application the reader has open.
        let parsed = ProcessInspector.parse(bytes)
        #expect(parsed.count <= 3)
    }

    @Test("A buffer too small to hold argc is empty, not a trap")
    func tooSmall() {
        #expect(ProcessInspector.parse([]) == [])
        #expect(ProcessInspector.parse([1, 2]) == [])
    }

    @Test("argc of zero is empty")
    func zeroArguments() {
        let bytes = buffer(argc: 0, executable: "/usr/bin/thing", padding: 2, arguments: [])
        #expect(ProcessInspector.parse(bytes) == [])
    }

    @Test("Arguments with spaces and backslashes survive, because Windows paths have both")
    func windowsPaths() {
        let bytes = buffer(
            argc: 2,
            executable: "/opt/wine/bin/wine64",
            padding: 3,
            arguments: ["wine64", "C:\\Program Files\\Team Fortress 2\\hl2.exe"]
        )
        #expect(ProcessInspector.parse(bytes).last == "C:\\Program Files\\Team Fortress 2\\hl2.exe")
    }
}
