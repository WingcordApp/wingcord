import Foundation
import QuartzCore
import WingcordCore
import WingcordVoice

// MARK: - Auto Clips
//
// docs/CLIPS-PRESENCE.md, Phase 7.2 (D19). While the replay buffer runs and
// Auto Clips is on, every second and a half:
//
//   * the game's events since the last look (`GameEventHub` — Dota 2,
//     Counter-Strike 2, League), and
//   * laughter and shouting in the last three seconds of what a clip may
//     keep — the call's consented voices and the reader's microphone — heard
//     by Apple's on-device classifier (`ClipEmotionListener`),
//
// go through `AutoClipPolicy`. A moment it keeps is saved five seconds later —
// so the reaction is in it — into the review folder, filed as an Auto Clip
// with its reason, for the reader to keep or throw away in the library.
// Nothing listens while the buffer is off, and nothing leaves the Mac.

@MainActor
final class AutoClips {
    private weak var model: AppModel?
    private var policy = AutoClipPolicy()
    private var task: Task<Void, Never>?
    /// The newest game event already weighed, on the host clock.
    private var seenEvents: Double = 0
    private let listener = ClipEmotionListener()
    /// How long after a moment the save waits, so the laugh is in the clip.
    static let postRoll: Double = 5
    /// How much an Auto Clip keeps, at most.
    static let longest: Double = 30

    init(model: AppModel) {
        self.model = model
    }

    /// Runs while the buffer runs and Auto Clips is on. Idempotent.
    func refresh() {
        let settings = AppSettings.shared
        let wanted = settings.clipsEnabled && settings.autoClipsEnabled && model?.clipRecorder.isArmed == true
        if wanted { start() } else { stop() }
        policy.listensForEmotion = settings.autoClipsHearsReactions
        policy.listensForGameEvents = settings.autoClipsHearsGameEvents
    }

    var isListening: Bool { task != nil }

    private func start() {
        guard task == nil else { return }
        policy = AutoClipPolicy()
        seenEvents = CACurrentMediaTime()
        Breadcrumbs.record("auto clips: listening")
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        Breadcrumbs.record("auto clips: stopped")
    }

    private func tick() async {
        guard let model else { return }
        let now = CACurrentMediaTime()
        var signals: [(time: Double, signal: AutoClipSignal)] = []
        if policy.listensForGameEvents {
            for moment in model.gameEvents.moments(from: seenEvents, to: now) where moment.time > seenEvents {
                signals.append((moment.time, .game(moment.kind, name: moment.name)))
            }
        }
        seenEvents = now
        if policy.listensForEmotion {
            let snapshot = model.clipRecorder.callTap.snapshot()
            let listener = listener
            let heard = await Task.detached(priority: .utility) {
                listener.listen(to: snapshot, from: now - 3, to: now)
            }.value
            if heard.laughter >= AutoClipPolicy.laughterFloor {
                signals.append((now - 1.5, .laughter(confidence: heard.laughter)))
            }
            if heard.shouting >= AutoClipPolicy.shoutingFloor {
                signals.append((now - 1.5, .shouting(confidence: heard.shouting)))
            }
        }
        for entry in signals.sorted(by: { $0.time < $1.time }) {
            if let trigger = policy.observe(entry.signal, at: entry.time) {
                keep(trigger)
            }
        }
    }

    /// Saves a kept moment once its reaction has had time to happen.
    private func keep(_ trigger: AutoClipTrigger) {
        Breadcrumbs.record("auto clips: keeping \(trigger.reason.name)")
        Task { [weak self] in
            let wait = max(0, trigger.time + Self.postRoll - CACurrentMediaTime())
            try? await Task.sleep(for: .seconds(wait))
            guard let self, let model = self.model else { return }
            let length = min(AppSettings.shared.clipLength.seconds, Self.longest)
            do {
                _ = try await model.clipRecorder.save(
                    seconds: length,
                    to: ClipLibrary.reviewFolder,
                    named: ClipLibrary.name(for: model.detectedGame?.name),
                    context: model.clipSaveContext(),
                    auto: trigger.reason
                )
                model.clipsRevision &+= 1
                model.overlay.showClipFeedback(.saved("Auto Clip — \(trigger.reason.name)"))
            } catch {
                Breadcrumbs.record("auto clips: save failed")
            }
        }
    }
}
