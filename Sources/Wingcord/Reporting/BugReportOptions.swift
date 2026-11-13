import SwiftUI

/// What goes with the report: the diagnostics (on), a picture of the window
/// (off, D21), and detailed logging for ten minutes (D23). An idea takes the
/// picture alone — there is nothing to diagnose.
///
/// **"See What's Sent" sits beside the diagnostics**, the thing it shows —
/// the control by what it affects.
struct BugReportOptions: View {
    @Bindable var reporter: BugReporter
    var showContents: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if reporter.draft.kind == .bug {
                diagnostics
            }

            ReportOptionRow(
                title: "Include a picture of the Wingcord window",
                detail: screenshotDetail,
                isOn: $reporter.draft.includesScreenshot
            ) {
                EmptyView()
            }
            .disabled(reporter.screenshot == nil)

            if reporter.draft.includesScreenshot, let preview = reporter.screenshotPreview {
                ScreenshotPreview(image: preview)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if reporter.draft.kind == .bug {
                DetailedLoggingOption()
            }
        }
    }

    private var diagnostics: some View {
        ReportOptionRow(
            title: "Include diagnostics",
            detail: "What the app was doing, crash reports, and what macOS noticed. No names, messages, addresses or tokens.",
            isOn: $reporter.draft.includesDiagnostics
        ) {
            Button("See What's Sent…", action: showContents)
                .buttonStyle(.link)
                .font(.system(.subheadline))
                .tint(Palette.accent)
                .disabled(!reporter.draft.isSubmittable)
                .help(reporter.draft.isSubmittable ? "Read every file in the report" : "Say what happened first")
        }
    }

    private var screenshotDetail: String {
        if reporter.screenshot != nil {
            return "The window as it was when you opened this, before the report covered it."
        }
        if case .afterCrash = reporter.draft.origin {
            return "Not for this report: the window is the new run's, not the one that went wrong."
        }
        return "The window could not be pictured."
    }
}

/// A checkbox with its explanation under the title, and room for a control
/// on its line.
struct ReportOptionRow<Accessory: View>: View {
    var title: String
    var detail: String
    @Binding var isOn: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body))
                        .foregroundStyle(Ink.primary)
                    Text(detail)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 0)
            accessory
        }
    }
}
