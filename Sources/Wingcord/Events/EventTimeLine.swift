import SwiftUI
import WingcordCore

/// When an event is, drawn as Discord draws it (`103355`): a calendar in the
/// accent, green while it is on, a clock once it is over, red when it is
/// cancelled — or a NEW mark in the icon's place for an event the reader has
/// not seen — and the repeat line under it for a series.
///
/// **Redrawn on the minute of the start, not of the wall clock**: "Starting in
/// 12m" turns over when a whole minute to the start has passed, so the
/// schedule is anchored on the start's own seconds.
struct EventTimeLine: View {
    var start: Date
    var end: Date?
    var status: ScheduledEvent.Status
    var isExternal: Bool
    var isCanceled = false
    var isNew = false
    var repeatLine: String?

    var body: some View {
        let clock = EventClock.current()
        // SwiftUI's, not the transcript's view of the same name.
        SwiftUI.TimelineView(.periodic(from: Self.anchor(for: start), by: 60)) { context in
            let line = EventTimeText(
                start: start, end: end, status: status, isExternal: isExternal,
                isCanceled: isCanceled, now: context.date, clock: clock
            )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                mark(line.state)
                VStack(alignment: .leading, spacing: 1) {
                    text(line)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    if let repeatLine {
                        Text(repeatLine)
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .help(line.detail ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text([line.spoken, repeatLine].compactMap(\.self).joined(separator: ", ")))
        }
    }

    @ViewBuilder
    private func mark(_ state: EventTimeText.State) -> some View {
        if isNew && status == .scheduled {
            Text("NEW")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Capsule().fill(Palette.accent))
        } else {
            Image(systemName: state == .ended ? "clock" : "calendar")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(markColor(state))
        }
    }

    private func markColor(_ state: EventTimeText.State) -> Color {
        switch state {
        case .live: Palette.presenceOnline
        case .canceled: Palette.destructive
        case .ended: InkColor.secondary
        case .later, .soon, .due: Palette.accent
        }
    }

    /// The words, with the live lead in green — the whole line where it says
    /// nothing else — and the accent while it is about to start.
    private func text(_ line: EventTimeText) -> Text {
        switch line.state {
        case .live:
            guard let lead = line.liveLead, line.text != lead else {
                return Text(line.text).foregroundStyle(Palette.presenceOnline)
            }
            let rest = String(line.text.dropFirst(lead.count))
            return Text("\(Text(lead).foregroundStyle(Palette.presenceOnline))\(Text(rest).foregroundStyle(InkColor.primary))")
        case .soon, .due:
            return Text(line.text).foregroundStyle(Palette.accent)
        case .later, .ended, .canceled:
            return Text(line.text).foregroundStyle(InkColor.primary)
        }
    }

    /// A moment no later than now that is a whole number of minutes before the
    /// start, so the periodic schedule ticks as each minute to it passes.
    private static func anchor(for start: Date) -> Date {
        let minutes = (start.timeIntervalSinceNow / 60).rounded(.up)
        return start.addingTimeInterval(-minutes * 60)
    }
}
