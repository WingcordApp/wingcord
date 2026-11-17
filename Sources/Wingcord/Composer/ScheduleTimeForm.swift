import SwiftUI
import WingcordCore

/// Discord's "Schedule Message" time picker (`896455`): a date, a time, and Set
/// Schedule — in the composer's `+` menu, over the scheduling bar, and beside
/// the poll editor's Post.
///
/// **A flyout's body, not a modal.** Every place that asks for a time is
/// already a flyout or a sheet, and a second surface over it would be a window
/// pointing at a row inside another one. It paints nothing of its own — §4.9.
///
/// **The field is bounded to the window it may answer**, ten minutes to eight
/// days out (`ScheduleWindow`), so a bad time cannot be typed. The bounds move
/// only when the form is drawn again, so a form left open past its own minimum
/// is checked once more on Set, and says so in Discord's words.
struct ScheduleTimeForm: View {
    /// Clear, when a time is already set — Discord's secondary button turns
    /// from Cancel into Clear when there is one to take away.
    var clear: (() -> Void)?
    var cancel: () -> Void
    var set: (Date) -> Void

    @State private var date: Date
    @State private var problem: ScheduleWindow.Problem?
    private let bounds: ClosedRange<Date>

    init(
        initial: Date,
        clear: (() -> Void)? = nil,
        cancel: @escaping () -> Void,
        set: @escaping (Date) -> Void
    ) {
        self.clear = clear
        self.cancel = cancel
        self.set = set
        let now = Date.now
        bounds = now.addingTimeInterval(ScheduleWindow.lead)...now.addingTimeInterval(ScheduleWindow.reach)
        _date = State(initialValue: min(max(initial, bounds.lowerBound), bounds.upperBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Date and Time")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .textCase(.uppercase)
                // **Wingcord's own picker, the one search uses** (Alex,
                // 2026-11-17): a calendar and two big numbers, bounded to the
                // window a schedule may answer.
                // **Fitted to the popover, never wider than it** (Alex,
                // 2026-11-17: a 260-point floor in a 248-point flyout cut "Date
                // and Time" and Cancel off at both sides). The well shortens
                // its own wording instead — see `PlayfulDatePicker`.
                PlayfulDatePicker(
                    selection: $date,
                    minimum: bounds.lowerBound,
                    accessibilityTitle: "Scheduled date and time",
                    maximum: bounds.upperBound
                )
            }
            if let problem {
                Text(problem.message)
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
            }
            HStack(spacing: Spacing.base) {
                Button(clear == nil ? "Cancel" : "Clear") { (clear ?? cancel)() }
                    .buttonStyle(.plain)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Spacing.base)
                Button("Set Schedule", action: commit)
                    .buttonStyle(.plain)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: 28)
                    .background(Palette.accent, in: .capsule)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.snug)
        .onChange(of: date) { problem = nil }
    }

    private func commit() {
        if let problem = ScheduleWindow.problem(with: date, at: .now) {
            self.problem = problem
            return
        }
        set(date)
    }
}
