import Foundation
import WingcordCore

// MARK: - Slowmode
//
// The store's half of `SlowmodeCooldown`: who is subject to a wait, and the
// three moments one is set — a send landing, the server volunteering what is
// left, and a channel's limit changing under a running wait.

extension AppModel {

    /// Whether the reader is exempt from this channel's slowmode.
    ///
    /// **`bypassSlowmode` and nothing else**, which is Discord's own test
    /// (module `960850`). It used to ride on Manage Messages; Discord split it
    /// out and migrated every role that held that — `PermissionCatalog` records
    /// the split — and an administrator holds it through the resolver's `.all`.
    func isSlowmodeImmune(in channelID: ChannelID) -> Bool {
        permissionGate.permissions(in: channelID).contains(.bypassSlowmode)
    }

    /// When the reader may send in this channel again, while they must wait.
    func slowmodeWait(in channelID: ChannelID, now: Date = .now) -> Date? {
        guard let cooldown = slowmodeCooldowns[channelID], cooldown.isRunning(at: now),
              !isSlowmodeImmune(in: channelID)
        else { return nil }
        return cooldown.endsAt
    }

    /// Holds a send back while slowmode says it must wait, and flashes the
    /// indicator so the reader can see why nothing happened.
    ///
    /// - Returns: true when the send must not go out.
    func holdsForSlowmode(_ channelID: ChannelID, now: Date = .now) -> Bool {
        guard slowmodeWait(in: channelID, now: now) != nil else { return false }
        nudgeSlowmode(in: channelID)
        return true
    }

    /// A send landed, so the channel's whole wait starts now.
    func startSlowmode(afterSendIn channelID: ChannelID, now: Date = .now) {
        guard let limit = channelIndex[channelID]?.rateLimitPerUser,
              !isSlowmodeImmune(in: channelID)
        else { return }
        setSlowmode(.afterSend(rateLimit: limit, now: now), in: channelID, now: now)
    }

    /// The server said how much of the wait is left — a typing answer, which is
    /// how a send made on another device reaches this composer.
    func applySlowmode(remaining: TimeInterval, in channelID: ChannelID, now: Date = .now) {
        guard let limit = channelIndex[channelID]?.rateLimitPerUser,
              !isSlowmodeImmune(in: channelID)
        else { return }
        setSlowmode(.reported(remaining, rateLimit: limit, now: now), in: channelID, now: now)
    }

    /// A send refused inside a wait this client did not know about.
    ///
    /// **A refusal with no wait in it still starts one**, at the channel's full
    /// limit: the server has said the reader is inside a cooldown, and letting
    /// the next Return go straight back out is a second refusal. The next typing
    /// answer corrects the length. Discord's own client sets nothing here, so
    /// its composer offers a send it knows will fail.
    func applySlowmodeRefusal(retryAfter: TimeInterval?, in channelID: ChannelID) {
        if let retryAfter {
            applySlowmode(remaining: retryAfter, in: channelID)
        } else {
            startSlowmode(afterSendIn: channelID)
        }
        nudgeSlowmode(in: channelID)
    }

    /// A channel changed; a running wait follows its new limit.
    ///
    /// Called for every channel event, and cheap for all but the handful of
    /// channels holding a wait — one dictionary miss.
    func reconcileSlowmode(in channelID: ChannelID, now: Date = .now) {
        guard let cooldown = slowmodeCooldowns[channelID] else { return }
        let limit = channelIndex[channelID]?.rateLimitPerUser ?? 0
        let next = cooldown.reconciled(toRateLimit: limit, now: now)
        guard next != cooldown else { return }
        slowmodeCooldowns[channelID] = next
    }

    /// **Expired waits are swept on the way in**, so the table holds what is
    /// running rather than every channel the reader has ever been slowed in.
    private func setSlowmode(_ cooldown: SlowmodeCooldown?, in channelID: ChannelID, now: Date) {
        guard let cooldown else { return }
        var next = slowmodeCooldowns.filter { $0.value.isRunning(at: now) }
        next[channelID] = cooldown
        slowmodeCooldowns = next
    }

    private func nudgeSlowmode(in channelID: ChannelID) {
        slowmodeNudgeToken &+= 1
        slowmodeNudge = SlowmodeNudge(channelID: channelID, token: slowmodeNudgeToken)
    }
}
