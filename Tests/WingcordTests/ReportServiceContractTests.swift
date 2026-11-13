import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The app against the real reports service (`ReportsWorker/`), run locally:
/// what the app sends must be what the Worker's checks accept. Opt-in, since
/// it needs the Worker running —
///
/// ```sh
/// cd ReportsWorker && npx wrangler dev --port 8799
/// WINGCORD_REPORTS_E2E=http://127.0.0.1:8799 swift test --filter ReportServiceContractTests
/// ```
@Suite(
    "The reports service, end to end",
    .enabled(if: ProcessInfo.processInfo.environment["WINGCORD_REPORTS_E2E"] != nil)
)
struct ReportServiceContractTests {
    private var uploader: ReportUploader {
        let endpoint = URL(string: ProcessInfo.processInfo.environment["WINGCORD_REPORTS_E2E"] ?? "http://127.0.0.1:8799")!
        return ReportUploader(endpoint: endpoint, session: URLSession(configuration: .ephemeral))
    }

    private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test("A bug after a crash, with its zip and picture, is taken whole")
    func bugAfterACrash() async throws {
        var draft = BugReportDraft()
        draft.summary = "End-to-end check: the call went quiet after sleep"
        draft.steps = "1. Join\n2. Sleep\n3. Wake"
        draft.area = .voice
        draft.origin = .afterCrash(.init(kind: .crash, file: URL(filePath: "/tmp/none.txt")))
        let crash = try #require(CrashSignature.read("""
            image-base 0x1 uuid E2E-\(UUID().uuidString)
            === SIGNAL 11 ===
            --- backtrace ---
            0   Wingcord                            0x0000000104162ecc Wingcord + 123456
            1   libdispatch.dylib                   0x0000000199229a34 _dispatch_call_block_and_release + 32
            """, kind: .crash))
        let contents = BugReportBuilder.build(
            draft: draft, facts: SystemFacts.gather(), screenshot: nil,
            directory: URL.temporaryDirectory, log: LogStore.inMemory(scrubber: .ephemeral())
        )
        let zip = try BugReportArchive.zip(contents)
        let submission = ReportSubmission.make(
            draft: draft, crash: crash, attachments: [.bundle, .screenshot],
            scrubber: .ephemeral(), install: ReportIdentity.derive(salt: Array(UUID().uuidString.utf8))
        )
        let sent = try await uploader.send(ReportUpload(submission: submission, bundle: zip, screenshot: try png(), title: "E2E"))
        #expect(sent.reportID.hasPrefix("WC-"))
        #expect(sent.missingParts.isEmpty, "the Worker took the zip and the picture")
        #expect(!sent.wasRepeat)
        let status = try await uploader.status(of: sent)
        #expect(status.status == .received)
    }

    @Test("An idea with words only is taken at once")
    func idea() async throws {
        var draft = BugReportDraft()
        draft.kind = .idea
        draft.summary = "End-to-end check: pin a chat to the sidebar"
        draft.origin = .slashCommand
        let submission = ReportSubmission.make(
            draft: draft, crash: nil, attachments: [],
            scrubber: .ephemeral(), install: ReportIdentity.derive(salt: Array(UUID().uuidString.utf8))
        )
        let sent = try await uploader.send(ReportUpload(submission: submission, bundle: nil, screenshot: nil, title: "E2E idea"))
        #expect(sent.kind == .idea)
        #expect(sent.missingParts.isEmpty)
    }
}
