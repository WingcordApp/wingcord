import AppKit
import SwiftUI

/// Wingcord's own date and time picker — Alex, 2026-10-26: "replacing the
/// native date picker with a custom date picker, something cool, unique,
/// playful".
///
/// **A well that reads like a sentence, and a calendar beside it.** The well
/// shows the day and the time the way a person says them ("Tue 27 Oct ·
/// 18:30"); a click opens a popover — the HIG's place for a picker, "below or
/// near the field being edited" — with the month as a grid of days, a row of
/// quick days, and the time as two big numbers that step by a click. The
/// graphical style, because choosing an event's day is browsing a calendar
/// (the HIG's own case for it).
///
/// **Playful where it is felt, not where it is in the way**: the chosen day
/// lands with a spring and a tick of the trackpad, the month slides the way
/// it was turned, and a quick pick pops. Minutes go in fives — "consider less
/// minute granularity", and nobody schedules an event for 18:23.
struct PlayfulDatePicker: View {
    @Binding var selection: Date
    /// The earliest moment that may be chosen — now, for an event that has
    /// not started.
    var minimum: Date?
    var accessibilityTitle: String
    /// Whether a time is chosen as well as a day. **Off for a day alone** —
    /// a search's before, during and after, where the hour means nothing.
    var showsTime = true
    /// The latest day that may be chosen — today, for a search, which cannot
    /// find a message from tomorrow.
    var maximum: Date? = nil
    /// Whether the quick days look back (Today, Yesterday, Last Week, Last
    /// Month) rather than ahead — a search is about what has been said.
    var looksBack = false

    @Environment(\.motion) private var motion
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            // **Whole words, then fewer of them**, rather than the day cut to
            // "Tue, 17 Nov 20…". Looking ahead the year goes first (a schedule
            // is days away; the year is never news); looking back — a search —
            // the weekday goes first, because last year is a real answer there.
            ViewThatFits(in: .horizontal) {
                well(date: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                if looksBack {
                    well(date: .dateTime.day().month(.abbreviated).year())
                } else {
                    well(date: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                }
                well(date: .dateTime.day().month(.abbreviated))
            }
            .font(.system(.body, weight: .medium))
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.composerControlHeight)
            .modalFieldGround(isFocused: isOpen)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(motion.standard, value: selection)
        .animation(motion.standard, value: isOpen)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DateTimeBoard(
                selection: $selection,
                minimum: minimum,
                maximum: maximum,
                showsTime: showsTime,
                looksBack: looksBack
            )
        }
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(showsTime
            ? Text(selection, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
            : Text(selection, format: .dateTime.weekday(.wide).day().month(.wide).year()))
        .accessibilityHint(Text("Opens a calendar"))
    }
}

extension PlayfulDatePicker {
    /// The well's one line, with the day written as `date` writes it.
    func well(date: Date.FormatStyle) -> some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "calendar")
                .foregroundStyle(Palette.accent)
            Text(selection, format: date)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
            if showsTime {
                Text(verbatim: "\u{00B7}")
                    .foregroundStyle(Ink.secondary)
                Image(systemName: "clock")
                    .foregroundStyle(Palette.accent)
                Text(selection, format: .dateTime.hour().minute())
                    .foregroundStyle(Ink.primary)
                    .monospacedDigit()
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
    }

    /// The month's days in weeks — blanks before the first and after the last,
    /// the week starting where the reader's calendar starts it.
    static func days(of month: Date, calendar: Calendar) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for day in range {
            cells.append(calendar.date(byAdding: .day, value: day - 1, to: month))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    /// One step of the hour or of the minute, wrapping inside the day so a
    /// step never changes the date the calendar shows. Minutes land on fives.
    static func stepped(_ date: Date, by delta: Int, unit: Calendar.Component, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        switch unit {
        case .hour:
            parts.hour = ((parts.hour ?? 0) + delta + 24) % 24
        default:
            let minute = parts.minute ?? 0
            let snapped = (minute / 5) * 5
            // Up goes to the next five; down to the five below, or to this
            // one where the minute sits between two.
            let next = delta > 0 ? snapped + 5 : (minute == snapped ? snapped - 5 : snapped)
            parts.minute = (next + 60) % 60
        }
        return calendar.date(from: parts) ?? date
    }
}

/// The popover: the month, the quick days, the time.
private struct DateTimeBoard: View {
    @Binding var selection: Date
    var minimum: Date?
    var maximum: Date?
    var showsTime: Bool
    var looksBack: Bool

    @Environment(\.motion) private var motion
    /// The first day of the month on show.
    @State private var month: Date
    /// Which way the last turn went — the way the next grid slides in.
    @State private var turnedForward = true

    private let calendar = Calendar.current

    init(selection: Binding<Date>, minimum: Date?, maximum: Date?, showsTime: Bool, looksBack: Bool) {
        _selection = selection
        self.minimum = minimum
        self.maximum = maximum
        self.showsTime = showsTime
        self.looksBack = looksBack
        let calendar = Calendar.current
        _month = State(initialValue: calendar.dateInterval(of: .month, for: selection.wrappedValue)?.start ?? selection.wrappedValue)
    }

    static let width: CGFloat = 296

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            header
            weekdays
            ZStack {
                grid
                    .id(month)
                    .transition(.modalStep(forward: turnedForward))
            }
            .clipped()
            quickDays
            if showsTime {
                Divider().overlay(Ink.quaternary)
                TimeSetter(selection: $selection)
            }
        }
        .padding(Spacing.margin)
        .frame(width: Self.width)
        .animation(motion.reposition, value: month)
    }

    // MARK: The month

    private var header: some View {
        HStack(spacing: Spacing.base) {
            Text(month, format: .dateTime.month(.wide).year())
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            turnButton("chevron.left", label: "Previous Month", by: -1)
            turnButton("chevron.right", label: "Next Month", by: 1)
        }
    }

    private func turnButton(_ symbol: String, label: String, by step: Int) -> some View {
        Button {
            guard let next = calendar.date(byAdding: .month, value: step, to: month) else { return }
            turnedForward = step > 0
            month = next
            Haptics.tick()
        } label: {
            Image(systemName: symbol)
                .font(.system(.caption, weight: .bold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        // A month with no day that may be chosen is not one to turn to — every
        // month after today, for a search.
        .disabled(!canTurn(by: step))
        .help(label)
        .accessibilityLabel(Text(label))
    }

    /// Whether the month `step` along has a day inside the bounds.
    private func canTurn(by step: Int) -> Bool {
        guard let next = calendar.date(byAdding: .month, value: step, to: month),
              let span = calendar.dateInterval(of: .month, for: next)
        else { return false }
        if let maximum, span.start > calendar.startOfDay(for: maximum) { return false }
        if let minimum, span.end <= calendar.startOfDay(for: minimum) { return false }
        return true
    }

    private var weekdays: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var grid: some View {
        let days = PlayfulDatePicker.days(of: month, calendar: calendar)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    DayCell(
                        day: day,
                        isSelected: calendar.isDate(day, inSameDayAs: selection),
                        isToday: calendar.isDateInToday(day),
                        isEnabled: isSelectable(day)
                    ) {
                        choose(day)
                    }
                } else {
                    Color.clear.frame(height: DayCell.side)
                }
            }
        }
    }


    private func isSelectable(_ day: Date) -> Bool {
        let start = calendar.startOfDay(for: day)
        if let minimum, start < calendar.startOfDay(for: minimum) { return false }
        if let maximum, start > calendar.startOfDay(for: maximum) { return false }
        return true
    }

    /// The day, keeping the time already chosen.
    private func choose(_ day: Date) {
        // A day alone is the day's start, which is what a search's clauses
        // measure from.
        guard showsTime else {
            withAnimation(motion.standard) { selection = calendar.startOfDay(for: day) }
            Haptics.tick()
            return
        }
        let time = calendar.dateComponents([.hour, .minute], from: selection)
        guard var chosen = calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day
        ) else { return }
        // Today, at a time that has gone by: the next hour instead.
        if let minimum, chosen < minimum {
            chosen = calendar.nextDate(after: minimum, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? minimum
        }
        withAnimation(motion.standard) { selection = chosen }
        Haptics.tick()
    }

    // MARK: Quick days

    /// **Whole words or one fewer**: when the four do not fit the board, the
    /// first goes (Today, which the grid's own ringed day already is) rather
    /// than the last being cut to "Last Mo…".
    private var quickDays: some View {
        let picks = (looksBack ? QuickDay.behind : QuickDay.ahead).compactMap { quick -> (QuickDay, Date)? in
            guard let day = quick.day(from: .now, calendar: calendar), isSelectable(day) else { return nil }
            return (quick, day)
        }
        return ViewThatFits(in: .horizontal) {
            quickRow(picks)
            quickRow(Array(picks.dropFirst()))
        }
    }

    private func quickRow(_ picks: [(QuickDay, Date)]) -> some View {
        HStack(spacing: Spacing.tight) {
            ForEach(picks, id: \.0) { quick, day in
                Button(quick.title) {
                    choose(day)
                    if let start = calendar.dateInterval(of: .month, for: day)?.start, start != month {
                        turnedForward = start > month
                        month = start
                    }
                    Haptics.pop()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private enum QuickDay: CaseIterable {
        case today, tomorrow, weekend, nextWeek
        case yesterday, lastWeek, lastMonth

        /// For something still to come — an event.
        static let ahead: [QuickDay] = [.today, .tomorrow, .weekend, .nextWeek]
        /// For what has already been said — a search.
        static let behind: [QuickDay] = [.today, .yesterday, .lastWeek, .lastMonth]

        var title: String {
            switch self {
            case .today: "Today"
            case .tomorrow: "Tomorrow"
            case .weekend: "Weekend"
            case .nextWeek: "Next Week"
            case .yesterday: "Yesterday"
            case .lastWeek: "Last Week"
            case .lastMonth: "Last Month"
            }
        }

        func day(from now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .today: now
            case .tomorrow: calendar.date(byAdding: .day, value: 1, to: now)
            case .weekend:
                // The coming Saturday — or today, on one.
                calendar.isDateInWeekend(now) ? now
                    : calendar.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)
            case .nextWeek: calendar.date(byAdding: .day, value: 7, to: now)
            case .yesterday: calendar.date(byAdding: .day, value: -1, to: now)
            case .lastWeek: calendar.date(byAdding: .day, value: -7, to: now)
            case .lastMonth: calendar.date(byAdding: .month, value: -1, to: now)
            }
        }
    }
}

/// One day: a number in a circle that the chosen one fills.
private struct DayCell: View {
    var day: Date
    var isSelected: Bool
    var isToday: Bool
    var isEnabled: Bool
    var choose: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    static let side: CGFloat = 34

    var body: some View {
        Button(action: choose) {
            Text(day, format: .dateTime.day())
                .font(.system(.callout, weight: isSelected || isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(Color.white)
                        : isEnabled ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.tertiary)
                )
                .frame(width: Self.side, height: Self.side)
                .background {
                    Circle()
                        .fill(isSelected ? AnyShapeStyle(Palette.accent) : isHovering && isEnabled ? AnyShapeStyle(Palette.hoverFill) : AnyShapeStyle(Color.clear))
                        .scaleEffect(isSelected ? 1 : 0.86)
                }
                .overlay {
                    if isToday, !isSelected {
                        Circle().strokeBorder(Palette.accent, lineWidth: 1.5)
                    }
                }
                .contentShape(.circle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
        }
        // The chosen day lands with a little bounce — it was pressed.
        .animation(motion.reduceMotion ? motion.standard : .spring(response: 0.28, dampingFraction: 0.62), value: isSelected)
        .animation(motion.hover, value: isHovering)
        .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The time: the hour and the minute as two big numbers, each stepped by the
/// arrows beside it, and four times people actually pick.
private struct TimeSetter: View {
    @Binding var selection: Date

    @Environment(\.motion) private var motion
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Label("Time", systemImage: "clock")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 0)
                stepper(unit: .hour)
                Text(verbatim: ":")
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                stepper(unit: .minute)
            }
            HStack(spacing: Spacing.tight) {
                ForEach([9, 12, 18, 21], id: \.self) { hour in
                    let time = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: selection) ?? selection
                    Button {
                        withAnimation(motion.standard) { selection = time }
                        Haptics.pop()
                    } label: {
                        Text(time, format: .dateTime.hour().minute())
                            .monospacedDigit()
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
        }
    }

    private func stepper(unit: Calendar.Component) -> some View {
        let value = calendar.component(unit, from: selection)
        let step = unit == .hour ? 1 : 5
        return HStack(spacing: 2) {
            Text(unit == .hour ? hourText(value) : String(format: "%02d", value))
                .font(.system(.title2, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Ink.primary)
                .contentTransition(.numericText(value: Double(value)))
                .frame(minWidth: 34)
            VStack(spacing: 0) {
                nudge("chevron.up", by: step, unit: unit)
                nudge("chevron.down", by: -step, unit: unit)
            }
        }
        .animation(motion.standard, value: value)
    }

    private func nudge(_ symbol: String, by delta: Int, unit: Calendar.Component) -> some View {
        Button {
            selection = PlayfulDatePicker.stepped(selection, by: delta, unit: unit, calendar: calendar)
            Haptics.tick()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 18, height: 12)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(delta > 0 ? "Later" : "Earlier"))
    }

    /// The hour as the reader's clock writes it — 18, or 6 PM.
    private func hourText(_ hour: Int) -> String {
        let probe = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: selection) ?? selection
        return probe.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

}
