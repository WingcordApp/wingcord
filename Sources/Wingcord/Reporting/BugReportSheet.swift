import SwiftUI
import UniformTypeIdentifiers

/// The bug report card (docs/BUG-REPORTING.md D21, D24, D28): the form, and
/// the pages it turns to in place — "See What's Sent", the sent report's id,
/// and Your Reports.
///
/// **A form card's anatomy** — `FormSheet`'s title, line, fields, then the way
/// out leading and the act trailing — with pages, because what would be
/// sent, what was sent and what became of it are the same task and not more
/// cards (INVARIANTS §1, "steps turn in place"). The way out is Close on the
/// form, not Cancel: the draft outlives the card (`BugReporter`), so closing
/// it loses nothing.
///
/// **The act is ⌘Return**: Return belongs to the two text areas, for their
/// lines (`FormSheet.confirmShortcut`).
struct BugReportSheet: View {
    @Bindable var reporter: BugReporter

    @Environment(\.motion) private var motion
    @ModalDismiss private var dismiss
    /// Whether the last turn went deeper — the way the next page slides.
    @State private var isGoingForward = true

    private let sentReports = SentReports.shared

    static let formWidth: CGFloat = 480
    static let contentsWidth: CGFloat = 720
    static let historyWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BugReportHeader(
                title: BugReportHeading.title(step: reporter.step, kind: reporter.draft.kind, sentKind: reporter.sent?.kind),
                subtitle: BugReportHeading.subtitle(step: reporter.step, kind: reporter.draft.kind)
            ) {
                headerAccessory
            }
            ZStack(alignment: .topLeading) {
                switch reporter.step {
                case .form:
                    BugReportForm(reporter: reporter, showContents: showContents)
                        .transition(.modalStep(forward: isGoingForward))
                case .contents:
                    BugReportContentsPage(reporter: reporter)
                        .transition(.modalStep(forward: isGoingForward))
                case .sent:
                    if let sent = reporter.sent {
                        BugReportSentPage(report: sent, showHistory: showHistory)
                            .transition(.modalStep(forward: isGoingForward))
                    }
                case .history:
                    YourReportsPage(store: sentReports)
                        .transition(.modalStep(forward: isGoingForward))
                }
            }
            BugReportFooter(
                step: reporter.step,
                kind: reporter.draft.kind,
                canSend: reporter.draft.isSubmittable,
                isSending: reporter.isSending,
                isSaving: reporter.isSaving,
                historyIsStandalone: reporter.historyIsStandalone,
                close: dismiss,
                back: back,
                save: save,
                send: send,
                done: dismiss
            )
        }
        .frame(width: width)
        .animation(motion.reposition, value: reporter.step)
        // A report on its way is not dropped by a click beside the card.
        .modalDismissDisabled(reporter.isSending)
        .fileExporter(
            isPresented: $reporter.isExporting,
            document: reporter.exportDocument,
            contentType: .zip,
            defaultFilename: reporter.exportName,
            onCompletion: reporter.finishExport
        )
    }

    private var width: CGFloat {
        switch reporter.step {
        case .form, .sent: Self.formWidth
        case .contents: Self.contentsWidth
        case .history: Self.historyWidth
        }
    }

    @ViewBuilder
    private var headerAccessory: some View {
        switch reporter.step {
        case .form where !sentReports.reports.isEmpty:
            Button("Your Reports", action: showHistory)
                .buttonStyle(.link)
                .font(.system(.subheadline))
                .tint(Palette.accent)
                .help("What you've sent from this Mac, and what became of it")
        case .history where sentReports.isRefreshing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking for news")
        default:
            EmptyView()
        }
    }

    private func showContents() {
        isGoingForward = true
        reporter.showContents()
    }

    private func showHistory() {
        isGoingForward = true
        reporter.showHistory()
    }

    /// Back from a page under the form: the form, or the sent page Your
    /// Reports was opened from.
    private func back() {
        isGoingForward = false
        if reporter.step == .history, reporter.sent != nil {
            reporter.step = .sent
        } else {
            reporter.showForm()
        }
    }

    private func save() {
        Task { await reporter.save() }
    }

    private func send() {
        isGoingForward = true
        Task { await reporter.send() }
    }
}
