import SwiftUI
import WingcordCore

/// Reads the store and works out what slowmode says about one channel.
///
/// **The countdown costs no body evaluations.** Its seconds are
/// `Text(timerInterval:)`, which the system redraws on its own clock; this view
/// wakes exactly once, when the wait ends, to put "Slowmode is enabled." back —
/// the typing indicator's sleeping task, for the typing indicator's reason. A
/// one-second timer here would be a timer running in every slowmode channel
/// somebody has open.
struct SlowmodeIndicatorContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// Bumped when a wait lapses, so the recomputed `Date()` reaches the screen.
    @State private var expiryTick: UInt64 = 0
    /// The held send being flashed for, by its nudge token; zero when none is.
    /// A token rather than a flag, so a second hold restarts the flash rather
    /// than being swallowed by the first.
    @State private var emphasis: UInt64 = 0

    var body: some View {
        let _ = expiryTick
        // The gate is `@ObservationIgnored`; this is the dependency both of its
        // answers below — sending, and immunity — actually move with.
        let _ = model.roleRevision
        let limit = model.channelIndex[channelID]?.rateLimitPerUser ?? 0
        // **Only where the reader can send.** Slowmode is a rule about sending,
        // and a locked thread or a read-only channel already says the one thing
        // worth saying above its foot.
        let shows = limit > 0 && model.permissionGate.canSend(in: channelID)
        let wait = shows ? model.slowmodeWait(in: channelID) : nil

        Group {
            if shows {
                SlowmodeIndicator(
                    phase: phase(wait: wait),
                    rateLimit: limit,
                    isEmphasized: emphasis != 0
                )
                .equatable()
                .transition(.materialize(from: .bottomTrailing, blurring: false))
            }
        }
        .animation(motion.standard, value: shows)
        .task(id: wait) {
            guard let wait else { return }
            let interval = wait.timeIntervalSinceNow
            guard interval > 0 else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            expiryTick &+= 1
        }
        .onChange(of: model.slowmodeNudge) { _, nudge in
            guard let nudge, nudge.channelID == channelID else { return }
            emphasis = nudge.token
        }
        .task(id: emphasis) {
            // Discord's `EMPHASIZE_SLOWMODE_COOLDOWN`: a second in the
            // warning colour, then back.
            guard emphasis != 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            emphasis = 0
        }
    }

    private func phase(wait: Date?) -> SlowmodeIndicator.Phase {
        if let wait { return .waiting(until: wait) }
        return model.isSlowmodeImmune(in: channelID) ? .immune : .enabled
    }
}

/// The trailing half of the line above the composer: a stopwatch, and what
/// slowmode says.
///
/// **The typing pill's own glass**, so the line reads as one row of notes
/// belonging to the composer rather than two unrelated badges. It stays up for
/// as long as the channel has slowmode, which is what Discord does and why: the
/// limit is worth knowing before the first message, not after the refusal.
///
/// Discord's three states and its words (module `960850`): "Slowmode is
/// enabled.", the wait counting down as `m:ss`, and "Slowmode Immune" for a
/// reader who holds Bypass Slowmode. The tooltip is its sentence about the
/// limit itself.
struct SlowmodeIndicator: View, Equatable {
    enum Phase: Equatable {
        /// Slowmode is on, and the reader may send.
        case enabled
        /// The reader may send again at this moment.
        case waiting(until: Date)
        /// The reader holds Bypass Slowmode.
        case immune
    }

    var phase: Phase
    /// The channel's limit, in seconds.
    var rateLimit: Int
    /// A send was just held back, and the pill says so in the warning colour.
    var isEmphasized: Bool

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "stopwatch")
                .font(.system(.caption, weight: .semibold))
                .opacity(isEmphasized ? 1 : 0.7)
            label
                .font(Typeface.rowSubtitle)
                // A countdown whose digits change width jiggles the pill once a
                // second.
                .monospacedDigit()
        }
        // Solid rather than the hierarchy, for the typing pill's reason: this
        // floats over the transcript, and a `.secondary` line resolves against
        // whatever message is scrolling under it. See `InkColor.solid`.
        .foregroundStyle(isEmphasized ? Palette.destructive : InkColor.solid)
        .lineLimit(1)
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, 5)
        // Status, not a control: a plain chip rather than glass.
        .plainChip(in: .capsule)
        // Never compressed: beside a long typing sentence it is the sentence
        // that truncates, and a countdown cut to "0:…" says nothing.
        .fixedSize()
        .padding(.trailing, Spacing.margin)
        .padding(.bottom, Spacing.tight)
        .animation(motion.standard, value: phase)
        .animation(motion.fadeQuick, value: isEmphasized)
        .help(SlowmodeSentence.describe(rateLimit: rateLimit))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var label: some View {
        switch phase {
        case .enabled:
            Text("Slowmode is enabled.")
        case .waiting(let end):
            // **Floored at the end.** A body evaluated a moment after the wait
            // ran out — an emphasis flip racing the expiry — would otherwise
            // build a range whose lower bound is past its upper one, and that
            // traps.
            Text(
                timerInterval: min(Date.now, end) ... end,
                countsDown: true,
                showsHours: rateLimit >= 3600
            )
        case .immune:
            Text("Slowmode Immune")
        }
    }

    private var accessibilityLabel: String {
        let sentence = SlowmodeSentence.describe(rateLimit: rateLimit)
        return switch phase {
        case .enabled: sentence
        case .waiting: "\(sentence) You can send another message in"
        case .immune: "Slowmode Immune. \(sentence)"
        }
    }

    private var accessibilityValue: Text {
        guard case .waiting(let end) = phase else { return Text(verbatim: "") }
        return Text(timerInterval: min(Date.now, end) ... end, countsDown: true)
    }

    static func == (lhs: SlowmodeIndicator, rhs: SlowmodeIndicator) -> Bool {
        lhs.phase == rhs.phase
            && lhs.rateLimit == rhs.rateLimit
            && lhs.isEmphasized == rhs.isEmphasized
    }
}
