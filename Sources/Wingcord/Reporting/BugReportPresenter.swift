import SwiftUI
import WingcordCore

/// The bug report's card and the after-crash question, mounted once at the
/// window root (docs/BUG-REPORTING.md D21).
struct BugReportPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    private let reporter = BugReporter.shared

    func body(content: Content) -> some View {
        // Read here, in the modifier's own body, so a request raised from a
        // menu or a task re-runs it — `JoinServerPresenter`'s rule.
        let _ = reporter.request
        let crashPrompt = reporter.crashPrompt

        return content
            .modal(item: requestBinding, onDismiss: reporter.close) { _ in
                BugReportSheet(reporter: reporter)
            }
            .modal(isPresented: crashPromptBinding, style: .alert) {
                if let crashPrompt {
                    CrashReportPrompt(ending: crashPrompt) { report in
                        reporter.answerCrashPrompt(report: report, model: model)
                    }
                }
            }
            .task {
                // Once the window is up behind it: a question asked over an
                // empty screen reads as part of the crash.
                try? await Task.sleep(for: .seconds(2))
                reporter.offerPreviousRunReport()
            }
    }

    private var requestBinding: Binding<BugReporter.Request?> {
        Binding(get: { reporter.request }, set: { reporter.request = $0 })
    }

    private var crashPromptBinding: Binding<Bool> {
        Binding(
            get: { reporter.crashPrompt != nil },
            set: { if !$0, reporter.crashPrompt != nil { reporter.answerCrashPrompt(report: false, model: model) } }
        )
    }
}

extension View {
    /// Applied once, at the window root, above `.environment(model)` and below
    /// `hostsModals`.
    func presentsBugReport() -> some View {
        modifier(BugReportPresenter())
    }
}
