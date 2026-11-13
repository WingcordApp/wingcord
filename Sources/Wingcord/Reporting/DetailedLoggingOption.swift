import SwiftUI

/// "Detailed logging for 10 minutes", as a checkbox, with the time left while
/// it is on (D23). The same switch as Settings › Diagnostics.
struct DetailedLoggingOption: View {
    @Bindable private var logging = DetailedLogging.shared

    var body: some View {
        ReportOptionRow(
            title: "Detailed logging for 10 minutes",
            detail: logging.isOn
                ? "On. Close this, make the problem happen again, then come back and save the report."
                : "Records every step of the connection and of calls while you make the problem happen again, then turns itself off.",
            isOn: $logging.isOnBinding
        ) {
            if logging.isOn {
                DetailedLoggingCountdown(logging: logging)
            }
        }
    }
}

/// `9:41 left`, ticking once a second while it is on.
struct DetailedLoggingCountdown: View {
    var logging: DetailedLogging

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(logging.remaining(at: context.date)) left")
                .font(.system(.subheadline, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Ink.primary)
                .contentTransition(.numericText(countsDown: true))
        }
        .accessibilityLabel(Text("Time left"))
    }
}
