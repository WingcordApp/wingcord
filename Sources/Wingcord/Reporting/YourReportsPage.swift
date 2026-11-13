import SwiftUI

/// Your Reports: what this Mac sent, newest first, and what became of each
/// (docs/BUG-REPORTING.md D28). The statuses are asked for as the page
/// opens; what was last heard shows meanwhile.
///
/// A short list sits in the card; a long one scrolls — `ViewThatFits`, as the
/// form does, since a `ScrollView` with no height of its own collapses a card.
struct YourReportsPage: View {
    var store: SentReports

    var body: some View {
        Group {
            if store.reports.isEmpty {
                ContentUnavailableView(
                    "No Reports Yet",
                    systemImage: "tray",
                    description: Text("Bugs and ideas you send from this Mac appear here, with what became of them.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ViewThatFits(in: .vertical) {
                    list
                    ScrollView { list }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: 440)
                }
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.reports) { report in
                SentReportRow(report: report)
                if report.id != store.reports.last?.id {
                    CardDivider()
                }
            }
        }
    }
}
