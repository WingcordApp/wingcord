import SwiftUI

/// A report's status, as a small capsule in its colour.
struct ReportStatusPill: View {
    var status: SentReport.Status

    var body: some View {
        Text(status.title)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .accessibilityLabel("Status: \(status.title)")
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
