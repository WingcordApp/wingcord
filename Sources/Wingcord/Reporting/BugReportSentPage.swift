import AppKit
import SwiftUI

/// The page a sent report turns to: its id, to quote, and what happens next
/// (docs/BUG-REPORTING.md D28).
///
/// **The id is the one thing to keep**, so it is the largest thing here, can
/// be selected, and has Copy beside it. A crash someone else already sent is
/// said to have been counted in — the developer sees how many it reaches —
/// and a file that did not upload is said plainly, with what to do.
struct BugReportSentPage: View {
    var report: SentReport
    var showHistory: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            HStack(alignment: .center, spacing: Spacing.snug) {
                Text(report.reportID)
                    .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Report \(report.reportID.map(String.init).joined(separator: " "))")
                Button(action: copy) {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .help("Copy the report's number")
            }

            Text(report.kind == .bug
                ? "Quote this number if you talk about the problem, here or in the Wingcord Discord server."
                : "Quote this number if you talk about the idea, here or in the Wingcord Discord server.")
                .font(.system(.body))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)

            if report.wasRepeat {
                Text("This crash was already reported, so yours was counted in with it — that tells the developer how many people it reaches.")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !report.missingParts.isEmpty {
                Label(
                    "The words arrived, but the \(missingDescription) didn't. If you're asked for them, open Report a Bug again and use Save Report….",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(.subheadline))
                .foregroundStyle(Palette.feedbackWarning)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("See Your Reports", action: showHistory)
                .buttonStyle(.link)
                .font(.system(.subheadline))
                .tint(Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private var missingDescription: String {
        let names = report.missingParts.map { $0 == "bundle" ? "diagnostics" : "picture" }
        return names.joined(separator: " and ")
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.reportID, forType: .string)
        didCopy = true
    }
}
