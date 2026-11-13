import AppKit
import SwiftUI

/// One sent report: what it was, its number and day, where it can be
/// followed once published, and its status.
struct SentReportRow: View {
    var report: SentReport

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.snug) {
            Image(systemName: report.kind == .bug ? "ladybug" : "lightbulb")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 22)
                .accessibilityLabel(report.kind == .bug ? "Bug" : "Idea")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.snug)
            if let issue = report.links.issue {
                Link(destination: issue) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .help("Open it on GitHub")
            }
            if let post = report.links.post {
                Link(destination: post) { Image(systemName: "bubble.left.and.bubble.right") }
                    .help("Open it in the Wingcord Discord server")
            }
            ReportStatusPill(status: report.status, kind: report.kind)
        }
        .padding(.vertical, Spacing.snug)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Report Number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.reportID, forType: .string)
            }
        }
    }

    private var title: String {
        if !report.title.isEmpty { return report.title }
        return report.kind == .bug ? "A bug report" : "An idea"
    }

    private var detail: String {
        var parts = [report.reportID, report.sentAt.formatted(date: .abbreviated, time: .omitted)]
        if report.wasRepeat { parts.append("counted in with others") }
        return parts.joined(separator: " · ")
    }
}
