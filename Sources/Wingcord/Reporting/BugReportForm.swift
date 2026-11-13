import AppKit
import SwiftUI

/// The report's first page: a bug or an idea, what it is, how it happens or
/// how it would be used, where, and what goes with it.
///
/// **The two text areas are the app's own editor** (`MarkdownEditor`), where
/// Return starts a new line — a vertical `TextField` hands Return to the
/// card's default button on macOS. **The options are checkboxes**: the HIG's
/// control for a single on/off choice in a window's body. **Bug and Idea are
/// the system's capsule strip** (`SegmentedPicker`), which switches what the
/// page asks for and keeps what was typed (D24).
///
/// A tall form scrolls and a short one does not — `FormSheet`'s
/// `ViewThatFits`, for the same reason: a `ScrollView` with no height of its
/// own is how a card collapses to a sliver.
struct BugReportForm: View {
    @Bindable var reporter: BugReporter
    var showContents: () -> Void

    @Environment(\.motion) private var motion
    @State private var isSummaryFocused = true
    @State private var isStepsFocused = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            fields
            ScrollView { fields }
                .scrollBounceBehavior(.basedOnSize)
        }
        .animation(motion.reposition, value: reporter.draft.includesScreenshot)
        .animation(motion.reposition, value: reporter.draft.kind)
        .animation(motion.reposition, value: reporter.failure)
        .animation(motion.reposition, value: reporter.sendFailure)
    }

    private var isIdea: Bool { reporter.draft.kind == .idea }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            SegmentedPicker(
                options: [
                    .init(ReportKind.bug, "Bug", symbolName: "ladybug", label: "Bug"),
                    .init(ReportKind.idea, "Idea", symbolName: "lightbulb", label: "Idea"),
                ],
                selection: $reporter.draft.kind,
                fillsWidth: true
            )
            .accessibilityLabel("A bug or an idea")

            SheetField(title: isIdea ? "What would you like Wingcord to do?" : "What happened", isRequired: true) {
                ReportTextArea(
                    text: $reporter.draft.summary,
                    isFocused: $isSummaryFocused,
                    placeholder: isIdea
                        ? "Pin a conversation to the top of the sidebar"
                        : "The call went quiet a minute after I joined",
                    lines: 3...8
                )
            }
            SheetField(
                title: isIdea ? "How would you use it?" : "Steps to make it happen again",
                detail: isIdea ? "Optional. When it would help, and why." : "Optional. What you did, in order."
            ) {
                ReportTextArea(
                    text: $reporter.draft.steps,
                    isFocused: $isStepsFocused,
                    placeholder: isIdea
                        ? "I keep three chats open all day and lose them among the rest"
                        : "1. Join a voice channel\n2. Turn on the camera",
                    lines: 2...6
                )
            }
            BugAreaRow(area: $reporter.draft.area)

            CardDivider()

            BugReportOptions(reporter: reporter, showContents: showContents)

            ReportDisclosure(kind: reporter.draft.kind)

            if let sendFailure = reporter.sendFailure {
                failureLine(sendFailure.message(for: reporter.draft.kind))
            }
            if let failure = reporter.failure {
                failureLine(failure)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private func failureLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(.subheadline))
            .foregroundStyle(Palette.destructive)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}
