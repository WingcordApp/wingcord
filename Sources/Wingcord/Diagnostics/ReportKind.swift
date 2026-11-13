/// A bug, or an idea for something Wingcord should do (docs/BUG-REPORTING.md
/// D24): one sheet, one draft, and the service's `kind`.
nonisolated enum ReportKind: String, CaseIterable, Codable, Hashable, Sendable {
    case bug
    case idea
}
