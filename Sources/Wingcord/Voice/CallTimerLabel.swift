import AppKit
import SwiftUI
import WingcordCore

/// How long the call has run — "7:39", "1:07:39" — turning over once a second.
///
/// **A view that draws its own digits, not `Text(timerInterval:)`.** The
/// system's timer text turns its digits over through the view graph it sits
/// in, and the call's lives in the sidebar's — the largest in the app. Each
/// second was an update of that whole graph: measured at rest in a call, the
/// app's main thread was busy a quarter of the time with nothing moving, and
/// the frame meter caught a hitch every second or two. Here a second costs one
/// short string drawn into one small layer, and the graph hears about it only
/// when the digits need more room — at ten minutes, and at an hour.
///
/// **A room's clock in the channel list is the same view** (`.room`). It was a
/// `TimelineView` on a one-second cadence inside that same graph, one phase
/// per room, so a server with four rooms running updated the sidebar four
/// times a second — the rule above, broken one row further down.
struct CallTimerLabel: NSViewRepresentable {
    var since: Date
    var style: CallTimerView.Style = .call

    func makeNSView(context: Context) -> CallTimerView {
        CallTimerView(since: since, style: style)
    }

    func updateNSView(_ view: CallTimerView, context: Context) {
        view.since = since
    }
}

final class CallTimerView: NSView {
    /// Whose clock it is: the call card's, or a room's row in the channel list.
    enum Style {
        case call
        case room
    }

    var since: Date {
        didSet {
            guard since != oldValue else { return }
            tick()
            if window != nil, AppVisibility.shared.isVisible { schedule() }
        }
    }

    private let style: Style
    private var text = ""
    private var size = CGSize.zero
    private var timer: Timer?

    /// The call card's callout or the room row's caption, with digits of one
    /// width so the line does not shuffle as they turn.
    private var font: NSFont {
        switch style {
        case .call:
            .monospacedDigitSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular
            )
        case .room:
            // `Typeface.voiceChannelClock`, which the count beside it wears.
            .monospacedDigitSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold
            )
        }
    }

    private static let roomInk = NSColor(Palette.presenceOnline)

    init(since: Date, style: Style = .call) {
        self.since = since
        self.style = style
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        tick()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else {
            AppVisibility.shared.stopObserving(self)
            return
        }
        // **Nothing ticks for a window nobody can see** (`INVARIANTS.md` §2).
        // The digits are put right the moment it can be seen again.
        AppVisibility.shared.observe(self) { [weak self] visible in
            guard let self, self.window != nil else { return }
            if visible {
                self.tick()
                self.schedule()
            } else {
                self.timer?.invalidate()
                self.timer = nil
            }
        }
        tick()
        if AppVisibility.shared.isVisible { schedule() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The ink resolves against this view's appearance while it draws, so
        // light, dark and Increase Contrast each get their own rung.
        let ink: NSColor = switch style {
        case .call: InkRamp.nsColor(.secondary)
        case .room: Self.roomInk
        }
        (text as NSString).draw(at: .zero, withAttributes: [
            .font: font,
            .foregroundColor: ink,
        ])
    }

    /// Fires on the call's own second boundaries, so the digits turn when the
    /// call's second does rather than up to a second late.
    private func schedule() {
        timer?.invalidate()
        let elapsed = max(0, Date().timeIntervalSince(since))
        let next = since.addingTimeInterval(elapsed.rounded(.down) + 1)
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let seconds = Int(max(0, Date().timeIntervalSince(since)))
        let next: String = switch style {
        case .call: Self.digits(seconds)
        // The activity card's clock: a reader who has learned one has learned both.
        case .room: ActivityCardContent.clock(seconds)
        }
        guard next != text else { return }
        text = next
        needsDisplay = true
        let measured = (next as NSString).size(withAttributes: [.font: font])
        let fitted = CGSize(width: measured.width.rounded(.up), height: measured.height.rounded(.up))
        // Only a change of width is news to the layout — the digit count, not
        // the digits.
        if fitted != size {
            size = fitted
            invalidateIntrinsicContentSize()
        }
    }

    /// Minutes and seconds, then hours as well — the system timer's shape, in
    /// the reader's own digits.
    static func digits(_ seconds: Int) -> String {
        let duration = Duration.seconds(seconds)
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    // MARK: Accessibility

    // A room's clock was hidden from VoiceOver as text, and stays so: the row
    // says who is in the room.
    override func isAccessibilityElement() -> Bool { style == .call }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Call duration" }

    override func accessibilityValue() -> Any? {
        let seconds = Int(max(0, Date().timeIntervalSince(since)))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
