import Foundation
import WingcordCore

/// A report as the reports service reads it: `POST /v1/reports`
/// (`ReportsWorker/src/validate.ts`, docs/BUG-REPORTING.md §9).
///
/// **Every field the service checks against a pattern is checked here
/// first**, and left out (or set to a plain fallback) when it would not pass,
/// so a Mac whose model the system cannot name still gets its report in. The
/// words are scrubbed as the bundle's are: no e-mail, token, address or id
/// leaves in them.
nonisolated struct ReportSubmission: Encodable, Equatable, Sendable {
    struct App: Encodable, Equatable, Sendable {
        var version: String
        var build: String
    }

    struct Crash: Encodable, Equatable, Sendable {
        var kind: String
        var signal: String?
        var fingerprint: String
        var frames: [String]
    }

    enum Part: String, Encodable, Sendable {
        case bundle
        case screenshot

        var contentType: String {
            switch self {
            case .bundle: "application/zip"
            case .screenshot: "image/png"
            }
        }
    }

    var kind: ReportKind
    var summary: String
    var details: String?
    var area: String
    var origin: String
    var app: App
    var macOS: String
    var model: String?
    var chip: String?
    var install: String
    var crash: Crash?
    var attachments: [Part]

    /// The service's limit for each of the two text fields, in characters.
    static let textLimit = 4000

    static func make(
        draft: BugReportDraft,
        crash: CrashSignature?,
        attachments: [Part],
        scrubber: LogScrubber,
        install: String = ReportIdentity.installID,
        bundle: Bundle = .main,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        model: String = SystemFacts.machineModel(),
        chip: String = SystemFacts.chip()
    ) -> ReportSubmission {
        let details = text(draft.steps, scrubber: scrubber)
        return ReportSubmission(
            kind: draft.kind,
            summary: text(draft.summary, scrubber: scrubber),
            details: details.isEmpty ? nil : details,
            area: draft.area.rawValue,
            origin: origin(of: draft.origin),
            app: App(
                version: bundle.shortVersion.wholeMatch(of: versionPattern) != nil ? bundle.shortVersion : "0",
                build: bundle.buildVersion.wholeMatch(of: buildPattern) != nil ? bundle.buildVersion : "0"
            ),
            macOS: macOS(system),
            model: model.wholeMatch(of: modelPattern) != nil ? model : nil,
            chip: chip.hasPrefix("unknown") || chip.wholeMatch(of: chipPattern) == nil ? nil : chip,
            install: install,
            // A crash goes with a bug written about it, and with nothing else.
            crash: draft.kind == .bug ? crash.map {
                Crash(kind: $0.kind.rawValue, signal: $0.signal, fingerprint: $0.fingerprint, frames: $0.frames)
            } : nil,
            attachments: attachments
        )
    }

    /// The service's names for where the sheet was opened.
    static func origin(of origin: BugReportOrigin) -> String {
        switch origin {
        case .menu: "menu"
        case .slashCommand: "command"
        case .settings: "settings"
        case .afterCrash(let ending): ending.kind == .hang ? "afterHang" : "afterCrash"
        }
    }

    /// `27.3`, or `27.3.1`: the numbers alone, as the service takes them.
    static func macOS(_ version: OperatingSystemVersion) -> String {
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        return text
    }

    private static func text(_ value: String, scrubber: LogScrubber) -> String {
        let scrubbed = scrubber.scrub(value.trimmingCharacters(in: .whitespacesAndNewlines))
        return scrubbed.count > textLimit ? String(scrubbed.prefix(textLimit)) : scrubbed
    }

    // The service's own patterns (`validate.ts`). Made when asked for: a
    // `Regex` is not `Sendable`, so it cannot be a stored static.
    private static var versionPattern: Regex<(Substring, Substring?)> { /\d{1,4}(\.\d{1,4}){0,3}/ }
    private static var buildPattern: Regex<Substring> { /\d{1,9}/ }
    private static var modelPattern: Regex<Substring> { /[A-Za-z]{2,24}\d{1,3},\d{1,3}/ }
    private static var chipPattern: Regex<Substring> { /[A-Za-z0-9 ()®™.,@-]{1,64}/ }
}
