import CryptoKit
import Foundation

/// The install, as the reports service knows it — for its per-Mac limit and
/// nothing else (docs/BUG-REPORTING.md §9).
///
/// **Derived one way from the log's salt, never the salt itself.** The salt
/// is what keeps the log's hashed ids from being turned back into real ones;
/// sending it would undo that. A hash of it, under a label of its own, says
/// "the same Mac as before" and nothing more.
nonisolated enum ReportIdentity {
    static let installID: String = derive(salt: InstallSalt.read(in: CrashReporter.reportDirectory))

    /// 32 hex characters.
    static func derive(salt: [UInt8]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("wingcord.reports.install.v1".utf8))
        hasher.update(data: Data(salt))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
