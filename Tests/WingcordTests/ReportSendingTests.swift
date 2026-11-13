import AppKit
import Foundation
import Synchronization
import Testing
@testable import Wingcord
@testable import WingcordCore

/// docs/BUG-REPORTING.md phase 6: a report leaving the app — its JSON as the
/// reports service reads it, the two-step upload, the answers it can get,
/// and the list of what was sent.
@Suite("Sending reports")
struct ReportSendingTests {

    // MARK: The install

    @Test("The install id is the salt's one-way hash: stable, 32 hex, and not the salt")
    func installID() {
        let salt = Array(repeating: UInt8(7), count: 32)
        let id = ReportIdentity.derive(salt: salt)
        #expect(id == ReportIdentity.derive(salt: salt))
        #expect(id.count == 32 && id.allSatisfy { $0.isHexDigit })
        #expect(!id.contains(salt.map { String(format: "%02x", $0) }.joined().prefix(16)))
        #expect(id != ReportIdentity.derive(salt: Array(repeating: UInt8(8), count: 32)))
    }

    // MARK: The JSON

    private func json(_ submission: ReportSubmission) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: Any])
    }

    private var crash: CrashSignature {
        CrashSignature(kind: .crash, signal: "SIGSEGV", fingerprint: String(repeating: "a", count: 32), frames: ["Wingcord x + 1"])
    }

    @Test("A bug after a crash says so, carries the crash, and keeps no address in its words")
    func bugJSON() throws {
        var draft = BugReportDraft()
        draft.summary = "  It crashed when I wrote to me@example.com  "
        draft.steps = ""
        draft.area = .voice
        draft.origin = .afterCrash(.init(kind: .crash, file: URL(filePath: "/tmp/crash-1.txt")))
        let submission = ReportSubmission.make(
            draft: draft, crash: crash, attachments: [.bundle, .screenshot],
            scrubber: LogScrubber(salt: Array("t".utf8)), install: String(repeating: "b", count: 32),
            system: OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0),
            model: "Mac17,2", chip: "Apple M5"
        )
        let object = try json(submission)
        #expect(object["kind"] as? String == "bug")
        #expect(object["summary"] as? String == "It crashed when I wrote to <email>")
        #expect(object["details"] == nil, "an empty field is left out, not sent empty")
        #expect(object["area"] as? String == "voice")
        #expect(object["origin"] as? String == "afterCrash")
        #expect(object["macOS"] as? String == "27.3")
        #expect(object["model"] as? String == "Mac17,2")
        #expect(object["chip"] as? String == "Apple M5")
        #expect(object["attachments"] as? [String] == ["bundle", "screenshot"])
        let app = try #require(object["app"] as? [String: String])
        #expect(app["version"] != nil && app["build"] != nil)
        let crashObject = try #require(object["crash"] as? [String: Any])
        #expect(crashObject["kind"] as? String == "crash")
        #expect(crashObject["signal"] as? String == "SIGSEGV")
        #expect(crashObject["frames"] as? [String] == ["Wingcord x + 1"])
    }

    @Test("An idea carries no crash, and what the service would refuse is left out")
    func ideaJSON() throws {
        var draft = BugReportDraft()
        draft.kind = .idea
        draft.summary = "Pin a chat"
        draft.steps = "Every morning"
        draft.origin = .slashCommand
        let submission = ReportSubmission.make(
            draft: draft, crash: crash, attachments: [],
            scrubber: .ephemeral(), install: String(repeating: "c", count: 32),
            system: OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 1),
            model: "unknown Mac", chip: "unknown chip"
        )
        let object = try json(submission)
        #expect(object["kind"] as? String == "idea")
        #expect(object["details"] as? String == "Every morning")
        #expect(object["origin"] as? String == "command")
        #expect(object["crash"] == nil)
        #expect(object["model"] == nil)
        #expect(object["chip"] == nil)
        #expect(object["macOS"] as? String == "27.3.1")
    }

    @Test("Where the sheet was opened, in the service's words")
    func origins() {
        #expect(ReportSubmission.origin(of: .menu) == "menu")
        #expect(ReportSubmission.origin(of: .slashCommand) == "command")
        #expect(ReportSubmission.origin(of: .settings) == "settings")
        #expect(ReportSubmission.origin(of: .afterCrash(.init(kind: .crash, file: URL(filePath: "/a")))) == "afterCrash")
        #expect(ReportSubmission.origin(of: .afterCrash(.init(kind: .hang, file: URL(filePath: "/a")))) == "afterHang")
    }

    @Test("A report's title is its first line, cut short")
    func title() {
        var draft = BugReportDraft()
        draft.summary = "\n  The call went quiet  \nand then it came back"
        #expect(BugReporter.title(of: draft) == "The call went quiet")
        draft.summary = String(repeating: "a", count: 200)
        #expect(BugReporter.title(of: draft).count == 80)
    }

    // MARK: The upload

    private func upload(kind: ReportKind = .bug, bundle: Data? = Data([0x50, 0x4B, 3, 4]), screenshot: Data? = nil) -> ReportUpload {
        var draft = BugReportDraft()
        draft.kind = kind
        draft.summary = "It went quiet"
        var parts: [ReportSubmission.Part] = []
        if bundle != nil { parts.append(.bundle) }
        if screenshot != nil { parts.append(.screenshot) }
        let submission = ReportSubmission.make(
            draft: draft, crash: nil, attachments: parts, scrubber: .ephemeral(),
            install: String(repeating: "d", count: 32)
        )
        return ReportUpload(submission: submission, bundle: bundle, screenshot: screenshot, title: "It went quiet")
    }

    @Test("A report goes as its JSON, then each part the service asks for, with its key")
    func sendsInTwoSteps() async throws {
        let server = StubServer { request, body in
            switch (request.httpMethod, request.url?.path()) {
            case ("POST", "/v1/reports"):
                return (201, #"{"id":"WC-4F2K","key":"k3y-k3y-k3y-k3y-k3y","upload":["bundle","screenshot"],"repeat":false}"#)
            case ("PUT", "/v1/reports/WC-4F2K/bundle"), ("PUT", "/v1/reports/WC-4F2K/screenshot"):
                return (204, "")
            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }
        let sent = try await server.uploader.send(upload(screenshot: Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(sent.reportID == "WC-4F2K")
        #expect(sent.key == "k3y-k3y-k3y-k3y-k3y")
        #expect(sent.missingParts.isEmpty)
        #expect(sent.status == .received)

        let requests = server.requests
        #expect(requests.map(\.line) == ["POST /v1/reports", "PUT /v1/reports/WC-4F2K/bundle", "PUT /v1/reports/WC-4F2K/screenshot"])
        #expect(requests[0].contentType == "application/json")
        let posted = try #require(JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        #expect(posted["summary"] as? String == "It went quiet")
        #expect(requests[1].authorization == "Bearer k3y-k3y-k3y-k3y-k3y")
        #expect(requests[1].contentType == "application/zip")
        #expect(requests[1].body == Data([0x50, 0x4B, 3, 4]))
        #expect(requests[2].contentType == "image/png")
    }

    @Test("A crash already in the inbox is counted, and nothing more is uploaded")
    func repeatUploadsNothing() async throws {
        let server = StubServer { request, _ in
            request.httpMethod == "POST"
                ? (201, #"{"id":"WC-AAAA","key":"another-key-0000000","upload":[],"repeat":true}"#)
                : (500, "")
        }
        let sent = try await server.uploader.send(upload())
        #expect(sent.wasRepeat)
        #expect(server.requests.count == 1)
    }

    @Test("A part that fails twice is named as missing; the words still went")
    func missingPart() async throws {
        let server = StubServer { request, _ in
            request.httpMethod == "POST"
                ? (201, #"{"id":"WC-BBBB","key":"key-key-key-key-key","upload":["bundle"],"repeat":false}"#)
                : (500, #"{"error":"internal"}"#)
        }
        let sent = try await server.uploader.send(upload())
        #expect(sent.missingParts == ["bundle"])
        #expect(server.requests.filter { $0.line.hasPrefix("PUT") }.count == 2, "tried once more")
    }

    @Test("Refusals become what the sheet can say")
    func refusals() async {
        for (status, body, expected) in [
            (429, #"{"error":"too_many_from_this_mac"}"#, ReportSendError.tooMany),
            (400, #"{"error":"invalid","field":"area"}"#, .refused(code: "invalid")),
            (503, "", .server(status: 503)),
            (201, "not json", .unreadable),
        ] {
            let server = StubServer { _, _ in (status, body) }
            await #expect(throws: expected) { try await server.uploader.send(upload()) }
        }
        let offline = StubServer(failsWith: URLError(.notConnectedToInternet))
        await #expect(throws: ReportSendError.offline) { try await offline.uploader.send(upload()) }
    }

    @Test("Every refusal tells a bug to save and an idea to wait")
    func refusalWords() {
        #expect(ReportSendError.offline.message(for: .bug).contains("save it as a file"))
        #expect(ReportSendError.offline.message(for: .idea).contains("Your idea stays here"))
    }

    @Test("Status: the service's word, or expired once it is gone")
    func status() async throws {
        let server = StubServer { request, _ in
            request.url?.path() == "/v1/reports/WC-CCCC"
                ? (200, #"{"id":"WC-CCCC","kind":"bug","status":"fixed","count":3,"links":{"issue":"https://github.com/example/wingcord/issues/12","post":"https://discord.com/channels/1/2"}}"#)
                : (404, #"{"error":"not_found"}"#)
        }
        let fixed = try await server.uploader.status(of: sentReport(id: "WC-CCCC"))
        #expect(fixed.status == .fixed)
        #expect(fixed.links.issue?.absoluteString == "https://github.com/example/wingcord/issues/12")
        #expect(fixed.links.post?.absoluteString == "https://discord.com/channels/1/2")
        let gone = try await server.uploader.status(of: sentReport(id: "WC-DDDD"))
        #expect(gone.status == .expired)
        #expect(server.requests.first?.authorization == "Bearer key-for-WC-CCCC")
    }

    @Test("An idea reads Added or Not Planned where a bug reads Fixed or Won't Fix")
    func statusWords() {
        #expect(SentReport.Status.fixed.title(for: .bug) == "Fixed")
        #expect(SentReport.Status.fixed.title(for: .idea) == "Added")
        #expect(SentReport.Status.wontfix.title(for: .bug) == "Won't Fix")
        #expect(SentReport.Status.wontfix.title(for: .idea) == "Not Planned")
        #expect(SentReport.Status.published.title(for: .idea) == "Published")
    }

    // MARK: Your Reports

    private func sentReport(id: String, status: SentReport.Status = .received) -> SentReport {
        SentReport(
            reportID: id, key: "key-for-\(id)", kind: .bug, title: id, sentAt: .now, wasRepeat: false,
            missingParts: [], status: status, links: .init(), checkedAt: nil
        )
    }

    @MainActor
    @Test("Sent reports are kept newest first, at most fifty, and read back")
    func keepsSentReports() throws {
        let url = URL.temporaryDirectory.appending(path: "sent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SentReports(url: url)
        for index in 0..<55 { store.add(sentReport(id: "WC-\(index)")) }
        #expect(store.reports.count == SentReports.kept)
        #expect(store.reports.first?.reportID == "WC-54")
        let reread = SentReports(url: url)
        #expect(reread.reports.map(\.reportID) == store.reports.map(\.reportID))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @MainActor
    @Test("Refreshing asks about every report still held, and leaves expired ones be")
    func refreshes() async {
        let url = URL.temporaryDirectory.appending(path: "sent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SentReports(url: url)
        store.add(sentReport(id: "WC-OLD1", status: .expired))
        store.add(sentReport(id: "WC-NEW1"))
        let service = AnsweringService(answer: .init(status: .published, links: .init()))
        await store.refresh(using: service)
        #expect(store.reports.first { $0.reportID == "WC-NEW1" }?.status == .published)
        #expect(store.reports.first { $0.reportID == "WC-OLD1" }?.status == .expired)
        #expect(service.asked.withLock { $0 } == ["WC-NEW1"])
    }

    // MARK: The picture

    @Test("A picture over the limit is scaled down until it fits, and stays a PNG")
    func fitsThePicture() throws {
        let side = 600
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        // Noise, so it does not compress away.
        var generator = SystemRandomNumberGenerator()
        let bytes = try #require(bitmap.bitmapData)
        for index in 0..<(side * side * 4) { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let limit = png.count / 4
        let fitted = try #require(ScreenshotFitting.fit(png, limit: limit))
        #expect(fitted.count <= limit)
        #expect(fitted.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(ScreenshotFitting.fit(png, limit: png.count) == png, "one that fits is left as it is")
    }
}

// MARK: - Test doubles

/// Answers the uploader's requests in place of the network: each server gets
/// its own made-up host, so tests running side by side never share answers.
nonisolated private final class StubServer: Sendable {
    struct Recorded: Sendable {
        var line: String
        var contentType: String?
        var authorization: String?
        var body: Data
    }

    typealias Handler = @Sendable (URLRequest, Data) -> (Int, String)

    /// What came in, in a box the stub's closure can hold (a `Mutex` cannot
    /// be copied into one).
    private final class Recorder: Sendable {
        let entries = Mutex<[Recorded]>([])
    }

    let host = "stub-\(UUID().uuidString.lowercased()).invalid"
    private let recorder = Recorder()

    init(handler: @escaping Handler) {
        StubProtocol.register(host: host) { [recorder] request, body in
            recorder.entries.withLock {
                $0.append(Recorded(
                    line: "\(request.httpMethod ?? "?") \(request.url?.path() ?? "?")",
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    body: body
                ))
            }
            return .success(handler(request, body))
        }
    }

    init(failsWith error: URLError) {
        StubProtocol.register(host: host) { _, _ in .failure(error) }
    }

    var requests: [Recorded] { recorder.entries.withLock { $0 } }

    var uploader: ReportUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ReportUploader(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
    }

    deinit { StubProtocol.unregister(host: host) }
}

nonisolated private final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest, Data) -> Result<(Int, String), URLError>

    private static let answers = Mutex<[String: Answer]>([:])

    static func register(host: String, answer: @escaping Answer) {
        answers.withLock { $0[host] = answer }
    }

    static func unregister(host: String) {
        _ = answers.withLock { $0.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host().map { host in answers.withLock { $0[host] != nil } } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let answer = Self.answers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch answer(request, Self.body(of: request)) {
        case .success(let (status, text)):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// An upload's body arrives as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A service that answers every status question the same way, and remembers
/// what it was asked.
nonisolated private final class AnsweringService: ReportService {
    let answer: ReportStatusAnswer
    let asked = Mutex<[String]>([])

    init(answer: ReportStatusAnswer) { self.answer = answer }

    func send(_ upload: ReportUpload) async throws(ReportSendError) -> SentReport { throw .offline }

    func status(of report: SentReport) async throws(ReportSendError) -> ReportStatusAnswer {
        asked.withLock { $0.append(report.reportID) }
        return answer
    }
}
