import Foundation

/// Sends a report to `reports.wingcord.app` (docs/BUG-REPORTING.md §9): the
/// JSON first, then each part the service asks for, with the key it hands
/// back.
///
/// **The service may ask for fewer parts than were announced** — none at all
/// for a crash already in the inbox, which it counts rather than stores
/// twice — so the parts sent are the ones it names, not the ones offered.
///
/// An ephemeral session: no cookies, no cache, nothing of the report left in
/// a URL cache on disk.
nonisolated struct ReportUploader: ReportService {
    static let productionEndpoint = URL(string: "https://reports.wingcord.app")!

    /// A developer's own copy of the service, e.g. `wrangler dev`:
    /// `defaults write dev.wingcord.Wingcord diagnostics.reportsEndpoint http://127.0.0.1:8787`.
    static let endpointKey = "diagnostics.reportsEndpoint"

    var endpoint: URL
    var session: URLSession

    static func standard(defaults: UserDefaults = .standard) -> ReportUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Wingcord/\(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))",
        ]
        let override = defaults.string(forKey: endpointKey).flatMap(URL.init(string:))
        return ReportUploader(endpoint: override ?? productionEndpoint, session: URLSession(configuration: configuration))
    }

    // MARK: Sending

    private struct Created: Decodable {
        var id: String
        var key: String
        var upload: [String]
        var `repeat`: Bool
    }

    func send(_ upload: ReportUpload) async throws(ReportSendError) -> SentReport {
        var request = URLRequest(url: endpoint.appending(path: "v1/reports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: Data
        do { body = try JSONEncoder().encode(upload.submission) } catch { throw .unreadable }

        let (data, response) = try await perform(request, body: body)
        guard response.statusCode == 201 else { throw Self.error(for: response, data: data) }
        let created = try Self.decode(Created.self, from: data)

        var missing: [String] = []
        for name in created.upload {
            guard let part = ReportSubmission.Part(rawValue: name),
                  let bytes = part == .bundle ? upload.bundle : upload.screenshot
            else {
                missing.append(name)
                continue
            }
            // Once more if it fails: a part is usually lost to a dropped
            // connection, and the words have already arrived.
            if (try? await put(bytes, part: part, of: created)) == nil,
               (try? await put(bytes, part: part, of: created)) == nil
            {
                missing.append(name)
            }
        }
        return SentReport(
            reportID: created.id,
            key: created.key,
            kind: upload.submission.kind,
            title: upload.title,
            sentAt: .now,
            wasRepeat: created.repeat,
            missingParts: missing,
            status: .received,
            links: .init(),
            checkedAt: nil
        )
    }

    private func put(_ bytes: Data, part: ReportSubmission.Part, of created: Created) async throws(ReportSendError) {
        var request = URLRequest(url: endpoint.appending(path: "v1/reports/\(created.id)/\(part.rawValue)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(created.key)", forHTTPHeaderField: "Authorization")
        request.setValue(part.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform(request, body: bytes)
        guard response.statusCode == 204 else { throw Self.error(for: response, data: data) }
    }

    // MARK: Status

    private struct StatusBody: Decodable {
        struct Links: Decodable {
            var issue: URL?
            var post: URL?
        }

        var status: String
        var links: Links
    }

    func status(of report: SentReport) async throws(ReportSendError) -> ReportStatusAnswer {
        var request = URLRequest(url: endpoint.appending(path: "v1/reports/\(report.reportID)"))
        request.setValue("Bearer \(report.key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request, body: nil)
        // Gone: the 90-day rule took it, since nobody published it.
        if response.statusCode == 404 { return ReportStatusAnswer(status: .expired, links: .init()) }
        guard response.statusCode == 200 else { throw Self.error(for: response, data: data) }
        let body = try Self.decode(StatusBody.self, from: data)
        return ReportStatusAnswer(
            status: SentReport.Status(rawValue: body.status) ?? .received,
            links: .init(issue: body.links.issue, post: body.links.post)
        )
    }

    // MARK: Plumbing

    private func perform(_ request: URLRequest, body: Data?) async throws(ReportSendError) -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            throw .offline
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadable }
        return (data, http)
    }

    private struct ErrorBody: Decodable {
        var error: String
    }

    static func error(for response: HTTPURLResponse, data: Data) -> ReportSendError {
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "unknown"
        switch response.statusCode {
        case 429: return .tooMany
        case 400..<500: return .refused(code: code)
        default: return .server(status: response.statusCode)
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws(ReportSendError) -> Value {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw .unreadable }
    }
}
