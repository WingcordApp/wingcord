import SwiftUI

/// The time detailed logging has left, while it is on — a row under its
/// switch, ticking once a second (docs/BUG-REPORTING.md D23).
struct DetailedLoggingTimeLeftRow: View {
    var logging: DetailedLogging

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            SettingsValueRow(title: "Time left", value: logging.remaining(at: context.date))
                .contentTransition(.numericText(countsDown: true))
        }
    }
}
