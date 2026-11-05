import SwiftUI
import WingcordCore

/// The bars sink to the centre line as a note's thrown away.
struct VoiceBarsSink: Transition {
    var reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(y: phase.isIdentity || reduceMotion ? 1 : 0.02, anchor: .center)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

extension Transition where Self == VoiceBarsSink {
    static func voiceBarsSink(reduceMotion: Bool) -> VoiceBarsSink {
        VoiceBarsSink(reduceMotion: reduceMotion)
    }
}

/// The dot and the time.
struct ComposerVoiceTimer: View {
    var note: ComposerVoiceNote

    @Environment(\.motion) private var motion
    private var reduceMotion: Bool { motion.reduceMotion }

    var body: some View {
        HStack(spacing: ComposerVoiceLayout.dotGap) {
            if note.phase == .recording {
                RecordingDot(reduceMotion: reduceMotion)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
            // A tenth of a second is as fine as these digits or their blink ever need, and
            // there's nothing to count at all for a note sitting in review.
            SwiftUI.TimelineView(.animation(
                minimumInterval: 0.1,
                paused: note.phase != .recording && !note.isPlaying
            )) { timeline in
                readout(at: timeline.date)
            }
        }
        .animation(motion.panel, value: note.phase)
    }

    private func readout(at date: Date) -> some View {
        let isRecording = note.phase == .recording
        let elapsed = note.clock.elapsed()
        let warning = isRecording ? VoiceNoteFlow.Warning(elapsedSeconds: elapsed) : .none
        let label: String = if isRecording {
            // Counting up in whole seconds, as a stopwatch does.
            VoiceWaveform.timeLabel(elapsed.rounded(.down))
        } else if let position = note.clock.position() {
            VoiceWaveform.timeLabel(note.durationSeconds - position)
        } else {
            VoiceWaveform.timeLabel(note.durationSeconds)
        }
        let isDark = warning.blinkInterval(reduceMotion: reduceMotion).map { interval in
            Int(date.timeIntervalSinceReferenceDate / interval) % 2 == 1
        } ?? false
        return Text(label)
            .font(.body.monospacedDigit().weight(.medium))
            .foregroundStyle(warning == .none ? AnyShapeStyle(InkColor.solid) : AnyShapeStyle(Color.red))
            .opacity(isDark ? 0.35 : 1)
            .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: !isRecording))
            .animation(motion.standard, value: label)
            .frame(minWidth: ComposerVoiceLayout.time, alignment: .leading)
            .fixedSize()
    }
}

/// A red dot, breathing while the microphone's open. Still under Reduce Motion.
private struct RecordingDot: View {
    var reduceMotion: Bool

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: ComposerVoiceLayout.dot, height: ComposerVoiceLayout.dot)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
    }
}

/// The bars themselves, on a `Canvas`, on the display's clock while anything's moving.
///
/// **Discord's numbers throughout, and nothing here holds a bar's state** beyond the live
/// row's values: going by, falling to dots, rising across the capsule, and swelling under
/// the playhead are all worked out from the clock on each frame.
struct ComposerVoiceBars: View {
    var note: ComposerVoiceNote
    var layout: ComposerVoiceLayout

    @Environment(\.motion) private var motion
    private var reduceMotion: Bool { motion.reduceMotion }
    /// Stopped moving, so the display's clock can rest until something changes.
    @State private var hasSettled = false
    @State private var cache = BarCache()

    /// A bar's values for a width, kept between frames since it costs a sort.
    private final class BarCache {
        var count = -1
        var values: [Float] = []
        var bars: [Float] = []
    }

    private var isLive: Bool {
        note.phase == .recording || note.isPlaying || !hasSettled
    }

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: !isLive)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .contentShape(.rect)
        // The press is the bars': only a held note can be moved through.
        .gesture(seekGesture, including: note.phase == .review ? .all : .none)
        .task(id: note.phase) {
            hasSettled = false
            guard note.phase == .review else { return }
            try? await Task.sleep(for: .seconds(VoiceWaveform.collapseDuration + VoiceWaveform.entranceDuration + 0.1))
            guard !Task.isCancelled else { return }
            hasSettled = true
        }
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A press from the bars on, and not one on the time beside them. A drag
                // that began there can go anywhere.
                guard value.startLocation.x >= ComposerVoiceLayout.reviewMinX - VoiceWaveform.barStep else { return }
                note.seek(fraction(atX: value.location.x, width: lastWidth), value.translation == .zero)
            }
    }

    /// The width the last frame was drawn at, for the gesture to work in.
    @State private var widthHolder = WidthHolder()
    private final class WidthHolder { var width: CGFloat = 0 }
    private var lastWidth: CGFloat { widthHolder.width }

    private func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        let minX = ComposerVoiceLayout.reviewMinX
        let room = width - layout.reviewReserve - minX
        guard room > 0 else { return 0 }
        return Double(max(0, min(1, (x - minX) / room)))
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        widthHolder.width = size.width
        switch note.phase {
        case .idle:
            // Never drawn: a strip only exists for a note, and one going away keeps the
            // state it was going away with, which is how its bars have something to sink.
            break
        case .recording:
            if reduceMotion {
                drawSweep(in: &context, size: size, now: now)
            } else {
                note.clock.meter.advance(to: now, level: note.clock.level())
                drawLive(in: &context, size: size, now: now)
            }
        case .review:
            let stoppedAt = reduceMotion ? nil : note.clock.stoppedAt()
            if let stoppedAt, now - stoppedAt < VoiceWaveform.collapseDuration {
                drawCollapse(in: &context, size: size, elapsed: now - stoppedAt)
            } else {
                drawReview(in: &context, size: size, now: now, stoppedAt: stoppedAt)
            }
        }
    }

    private func bar(atX x: CGFloat, height: CGFloat, midY: CGFloat) -> Path {
        Path(
            roundedRect: CGRect(
                x: x, y: midY - height / 2,
                width: VoiceWaveform.barWidth, height: height
            ),
            cornerRadius: VoiceWaveform.barCorner
        )
    }

    /// Bars near the time dissolve rather than being cut off by it.
    private func fade(atX x: CGFloat, minX: CGFloat) -> Double {
        Double(max(0, min(1, (x - minX) / 18)))
    }

    /// Going by: the newest entering beside the stop button, the rest sliding left.
    private func drawLive(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let meter = note.clock.meter
        let maxX = size.width - layout.recordingReserve
        let minX = ComposerVoiceLayout.liveMinX
        let step = VoiceWaveform.barStep
        let offset = step * (1 - meter.stepProgress)
        let count = meter.bars.count
        var solid = Path()
        for (index, bar) in meter.bars.enumerated() {
            let x = maxX - CGFloat(count - index) * step + offset
            guard x >= minX else { continue }
            let path = self.bar(
                atX: x,
                height: meter.height(of: bar, at: now, reduceMotion: false),
                midY: size.height / 2
            )
            let opacity = fade(atX: x, minX: minX)
            if opacity >= 1 {
                solid.addPath(path)
            } else {
                context.fill(path, with: .color(InkColor.solid.opacity(opacity)))
            }
        }
        context.fill(solid, with: .color(InkColor.solid))
    }

    /// Reduce Motion's bars: nothing crosses the capsule. They stay put and the newest
    /// value is written over the oldest, sweeping left to right.
    private func drawSweep(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let meter = note.clock.meter
        meter.advance(to: now, level: note.clock.level())
        let minX = ComposerVoiceLayout.liveMinX
        let maxX = size.width - layout.recordingReserve
        let slots = VoiceWaveform.barCount(forWidth: maxX - minX)
        guard slots > 0 else { return }
        var heights = [CGFloat](repeating: VoiceWaveform.barMinimumHeight, count: slots)
        let bars = meter.bars
        let total = meter.total
        for offset in 0..<min(slots, bars.count) {
            let serial = total - 1 - offset
            heights[serial % slots] = VoiceWaveform.barHeight(bars[bars.count - 1 - offset].value)
        }
        var path = Path()
        for slot in 0..<slots {
            path.addPath(bar(
                atX: minX + CGFloat(slot) * VoiceWaveform.barStep,
                height: heights[slot],
                midY: size.height / 2
            ))
        }
        context.fill(path, with: .color(InkColor.solid))
    }

    /// Stopped: the live bars fall to dots where they are, left to right.
    private func drawCollapse(in context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let meter = note.clock.meter
        let maxX = size.width - layout.recordingReserve
        let minX = ComposerVoiceLayout.liveMinX
        let step = VoiceWaveform.barStep
        let offset = step * (1 - meter.stepProgress)
        let total = meter.bars.count
        let visible = max(1, min(total, Int((maxX - minX) / step)))
        var solid = Path()
        for (index, bar) in meter.bars.enumerated() {
            let x = maxX - CGFloat(total - index) * step + offset
            guard x >= minX else { continue }
            let position = index - (total - visible)
            let value = VoiceWaveform.collapsed(bar.value, elapsed: elapsed, index: position, count: visible)
            solid.addPath(self.bar(atX: x, height: VoiceWaveform.barHeight(value), midY: size.height / 2))
        }
        context.fill(solid, with: .color(InkColor.solid))
    }

    /// The held note, across the capsule: rising from dots if it's just stopped, with the
    /// part that's been played in the accent, and swelling under the playhead.
    private func drawReview(
        in context: inout GraphicsContext, size: CGSize, now: TimeInterval, stoppedAt: TimeInterval?
    ) {
        let minX = ComposerVoiceLayout.reviewMinX
        let room = size.width - layout.reviewReserve - minX
        let count = VoiceWaveform.barCount(forWidth: room)
        guard count > 0 else { return }
        if cache.count != count || cache.values != note.values {
            cache.count = count
            cache.values = note.values
            cache.bars = VoiceWaveform.displayed(VoiceWaveform.bars(note.values, count: count))
        }
        let bars = cache.bars
        let position = note.clock.position()
        let duration = note.durationSeconds
        let played = position.map { seconds in
            duration > 0 ? Int((seconds / duration * Double(count)).rounded()) : 0
        } ?? 0
        let rate = Double(note.clock.rate())
        let sinceEntrance = stoppedAt.map { now - $0 - VoiceWaveform.collapseDuration }
        let isEntering = sinceEntrance.map { $0 < VoiceWaveform.entranceDuration } ?? false
        var unplayedPath = Path()
        var playedPath = Path()
        for index in 0..<count {
            var value = bars[index]
            if let sinceEntrance, isEntering {
                value *= VoiceWaveform.entrance(elapsed: sinceEntrance, index: index, count: count)
            }
            let isPlayed = index < played
            if isPlayed, note.isPlaying, !reduceMotion, let position {
                let passedAt = Double(index + 1) / Double(count) * duration
                value = VoiceWaveform.popped(value, age: (position - passedAt) / max(rate, 0.25))
            }
            let path = bar(
                atX: minX + CGFloat(index) * VoiceWaveform.barStep,
                height: VoiceWaveform.barHeight(value),
                midY: size.height / 2
            )
            if isPlayed {
                playedPath.addPath(path)
            } else {
                unplayedPath.addPath(path)
            }
        }
        // Dots appearing where a short recording had none, rather than popping in.
        let appear = isEntering ? min(1, (sinceEntrance ?? 0) / 0.06) : 1
        context.fill(unplayedPath, with: .color(InkColor.solid.opacity(appear)))
        context.fill(playedPath, with: .color(Palette.accent))
    }
}
