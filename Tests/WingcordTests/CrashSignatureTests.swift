import Foundation
import Testing
@testable import Wingcord

/// docs/BUG-REPORTING.md §9: a crash's fingerprint, which the reports service
/// folds repeats by — equal for the same crash in the same build, different
/// otherwise, and blind to where the app happened to be loaded.
@Suite("Crash signatures")
struct CrashSignatureTests {

    /// A real report's shape (`CrashReporter.handle`), the voice-join crash of
    /// 12 November, with its addresses moved by `shift` as a relaunch moves them.
    private func crashReport(shift: UInt64 = 0, build: String = "06A5A33A-E246-3FC0-8D11-2A37AD7A6888", appOffset: Int = 160, systemOffset: Int = 112) -> String {
        func address(_ value: UInt64) -> String { "0x" + String(format: "%016llx", value + shift) }
        return """

        === SIGNAL 5 ===
        footprint-bytes 163103992
        image-base 0x\(String(0x102d90000 + shift, radix: 16)) uuid \(build)
        --- breadcrumbs ---
        voice joined #1a2b3c4d
        --- backtrace ---
        0   Wingcord                            \(address(0x10335b464)) $s8Wingcord13CrashReporterO6handle6signalys5Int32V_tFZ + 732
        1   libsystem_platform.dylib            \(address(0x199273144)) _sigtramp + 56
        2   libdispatch.dylib                   \(address(0x19925fabc)) _dispatch_assert_queue_fail + \(systemOffset)
        3   libdispatch.dylib                   \(address(0x199260550)) dispatch_assert_queue$V2.cold.2 + 0
        4   libdispatch.dylib                   \(address(0x19922d108)) dispatch_assert_queue + 108
        5   libswift_Concurrency.dylib          \(address(0x198379df8)) _swift_task_checkIsolatedSwift + 48
        6   Wingcord                            \(address(0x104162ecc)) $s8Wingcord15VoiceControllerC22adoptSystemMuteGestureyyFS2bcfU_ + \(appOffset)
        7   Wingcord                            \(address(0x10416325c)) $sS2bIegyd_S2bIeyByd_TR + 40
        8   AudioSession                        \(address(0x1d2afe368)) -[AVAudioApplication(macOS) privateCallInputMuteHandlerBlock:inputMuted:isTopDownMute:context:] + 196

        """
    }

    @Test("A crash reads as its signal and the frames after the handler's own")
    func readsACrash() throws {
        let signature = try #require(CrashSignature.read(crashReport(), kind: .crash, mainImage: "Wingcord"))
        #expect(signature.kind == .crash)
        #expect(signature.signal == "SIGTRAP")
        #expect(signature.frames.first == "libdispatch.dylib _dispatch_assert_queue_fail + 112")
        #expect(signature.frames.count == 7)
        #expect(!signature.frames.contains { $0.contains("_sigtramp") || $0.contains("CrashReporter") })
        #expect(!signature.frames.contains { $0.contains("0x") }, "no address leaves in a frame")
        #expect(signature.fingerprint.count == 32)
        #expect(signature.fingerprint.allSatisfy { $0.isHexDigit })
    }

    @Test("The same crash after a relaunch has the same fingerprint")
    func blindToWhereTheAppLoaded() throws {
        let first = try #require(CrashSignature.read(crashReport(), kind: .crash, mainImage: "Wingcord"))
        let relaunched = try #require(CrashSignature.read(crashReport(shift: 0x4_0000), kind: .crash, mainImage: "Wingcord"))
        #expect(first.fingerprint == relaunched.fingerprint)
    }

    @Test("Another build, or another place in the app, is another crash; a macOS update is not")
    func whatSetsCrashesApart() throws {
        let base = try #require(CrashSignature.read(crashReport(), kind: .crash, mainImage: "Wingcord")).fingerprint
        let otherBuild = try #require(CrashSignature.read(
            crashReport(build: "11111111-2222-3333-4444-555555555555"), kind: .crash, mainImage: "Wingcord"
        )).fingerprint
        let otherPlace = try #require(CrashSignature.read(crashReport(appOffset: 176), kind: .crash, mainImage: "Wingcord")).fingerprint
        let systemUpdated = try #require(CrashSignature.read(crashReport(systemOffset: 120), kind: .crash, mainImage: "Wingcord")).fingerprint
        #expect(otherBuild != base)
        #expect(otherPlace != base)
        #expect(systemUpdated == base, "a system library's frame is named without its offset")
    }

    @Test("A freeze reads from the watchdog's two-second stack, with no signal")
    func readsAFreeze() throws {
        let marker = """
        Wingcord's main thread stopped answering at 2026-11-13T08:00:00Z.
        image-base 0x102d90000 uuid 06A5A33A-E246-3FC0-8D11-2A37AD7A6888

        --- main thread, two seconds in ---
        0 libsystem_kernel.dylib mach_msg2_trap + 8
        1 Wingcord +0x1a2b3c
        2 SwiftUI ViewGraph.updateOutputs + 112

        --- main thread, a quarter second in ---
        0 Wingcord +0x999
        """
        let signature = try #require(CrashSignature.read(marker, kind: .hang, mainImage: "Wingcord"))
        #expect(signature.kind == .hang)
        #expect(signature.signal == nil)
        #expect(signature.frames == [
            "libsystem_kernel.dylib mach_msg2_trap + 8",
            "Wingcord +0x1a2b3c",
            "SwiftUI ViewGraph.updateOutputs + 112",
        ])
    }

    @Test("An uncaught exception reads from where it was thrown, past the throwing machinery")
    func readsAnException() throws {
        let report = """

        === UNCAUGHT EXCEPTION ===
        name: NSInvalidArgumentException
        image-base 0x102d90000 uuid 06A5A33A-E246-3FC0-8D11-2A37AD7A6888
        --- call stack ---
        0   CoreFoundation                      0x00000001992f2f10 __exceptionPreprocess + 176
        1   libobjc.A.dylib                     0x0000000198dd6b10 objc_exception_throw + 88
        2   AppKit                              0x000000019d2a1234 -[NSTableView _invalidRow:] + 400
        3   Wingcord                            0x0000000104162ecc Wingcord + 20393676

        === SIGNAL 6 ===
        --- backtrace ---
        0   Wingcord                            0x000000010335b464 Wingcord + 1234
        1   libsystem_platform.dylib            0x0000000199273144 _sigtramp + 56
        2   libsystem_kernel.dylib              0x0000000199200000 __pthread_kill + 8
        """
        let signature = try #require(CrashSignature.read(report, kind: .crash, mainImage: "Wingcord"))
        #expect(signature.signal == "SIGABRT")
        #expect(signature.frames.first == "AppKit -[NSTableView _invalidRow:] + 400")
        #expect(signature.frames.count == 2)
    }

    @Test("A file with no stack has no signature, and a frame is printable and short")
    func edges() throws {
        #expect(CrashSignature.read("=== SIGNAL 11 ===\nfootprint-bytes 1\n", kind: .crash) == nil)
        #expect(CrashSignature.read("", kind: .hang) == nil)

        let long = String(repeating: "é", count: 300)
        let report = """
        --- backtrace ---
        0   Wingcord                            0x0000000104162ecc \(long) + 1
        """
        let signature = try #require(CrashSignature.read(report, kind: .crash, mainImage: "Wingcord"))
        let frame = try #require(signature.frames.first)
        #expect(frame.count <= CrashSignature.frameLength)
        #expect(frame.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) })
    }
}
