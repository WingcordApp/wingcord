import SwiftUI

/// "See What's Sent": every file in the report on the leading side, the one
/// picked on the trailing side, exactly as it would go (docs/BUG-REPORTING.md
/// §2, principle 3).
///
/// Built when the page opens, from the draft as it stands — off the main
/// actor, since the log alone is megabytes of text to read and scrub.
struct BugReportContentsPage: View {
    @Bindable var reporter: BugReporter
    @State private var selection = "report.txt"

    static let height: CGFloat = 400

    var body: some View {
        Group {
            if let contents = reporter.contents, !reporter.isBuildingContents {
                HStack(alignment: .top, spacing: Spacing.margin) {
                    BugReportFileList(contents: contents, selection: $selection)
                        .frame(width: 220)
                    BugReportFileViewer(file: contents.files.first { $0.name == selection } ?? contents.files.first)
                }
            } else {
                ProgressView {
                    Text("Putting the report together…")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }
}
