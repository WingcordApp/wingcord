import Foundation
import WingcordCore
import WingcordNet

/// Throwing Orbs, batched as Discord's client does (`294278`, `442928`): sent
/// five seconds after the last throw — at once for the first throw and for one
/// that crosses into a new level — under a fresh `sink_id` each, retried after
/// a server error or a rate limit and never after a refusal.
extension SessionController {
    func loadOrbVoid() {
        Task { [weak self] in
            guard let self else { return }
            do {
                model.orbVoid.status = try await rest.orbVoidStatus()
                model.orbVoid.loadFailed = false
            } catch {
                model.orbVoid.loadFailed = true
                Self.trace("orb void status failed: \(Self.describe(error))")
            }
        }
    }

    /// One Orb into the Void.
    func throwOrb() {
        guard model.canThrowOrb else { return }
        let before = model.orbVoidTotal ?? 0
        model.orbVoid.pending += 1
        let after = before + 1
        let levels = model.orbVoidLevels.map(\.threshold)
        let crossesLevel = levels.contains { before < $0 && after >= $0 }
        orbVoidFlush?.cancel()
        if before == 0 || crossesLevel {
            flushOrbVoid()
        } else {
            orbVoidFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.flushOrbVoid()
            }
        }
    }

    /// Sends what is pending as one batch.
    func flushOrbVoid(attempt: Int = 0) {
        let quantity = model.orbVoid.pending
        guard quantity > 0, !model.orbVoid.isRejected else { return }
        model.orbVoid.pending = 0
        model.orbVoid.inFlight += quantity
        let sinkID = UUID().uuidString.lowercased()
        let at = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await rest.throwOrbs(sinkID: sinkID, quantity: quantity, at: at)
                model.orbVoid.inFlight -= quantity
                model.orbVoid.status?.balance = snapshot.balance
                model.orbVoid.status?.totalBurned = snapshot.totalBurned
                Log.info(.app, "orb void: threw \(public: String(quantity))")
            } catch let failure as DiscordREST.Failure where failure.isRetryable && attempt < 6 {
                // Back where it was, and again after a wait that grows.
                model.orbVoid.inFlight -= quantity
                model.orbVoid.pending += quantity
                try? await Task.sleep(for: .seconds(min(60, 1 << attempt)))
                flushOrbVoid(attempt: attempt + 1)
            } catch {
                model.orbVoid.inFlight -= quantity
                model.orbVoid.isRejected = true
                Self.trace("orb void throw refused: \(Self.describe(error))")
            }
        }
    }
}
