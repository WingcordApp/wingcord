import SwiftUI

/// A report's status, as a small capsule in its colour.
struct ReportStatusPill: View {
    var status: SentReport.Status
    var kind: ReportKind

    var body: some View {
        Text(status.title(for: kind))
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .accessibilityLabel("Status: \(status.title(for: kind))")
    }

    private var color: Color {
        switch status {
        case .received, .published: Palette.accent
        case .solved, .fixed: Palette.affirmative
        case .wontfix: Palette.feedbackWarning
        case .expired: Palette.presenceOffline
        }
    }
}
