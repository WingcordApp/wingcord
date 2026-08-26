import Foundation

/// Discord's rate limits, respected without serialising the whole client.
///
/// **Per-bucket, not global**, and that distinction is the difference between an
/// app that feels instant and one that does not. Discord limits per *route
/// bucket* — sending in one channel, fetching history in another, and adding a
/// reaction are three independent budgets — so a single global queue makes every
/// request wait behind the slowest unrelated one. A history fetch would then be
/// blocked by a typing indicator.
///
/// An actor rather than a lock: acquiring a slot can *suspend* (waiting out a
/// reset), and a lock held across a suspension is either a deadlock or a thread
/// parked doing nothing.
public actor RateLimiter {

    /// One bucket's remaining budget.
    private struct Bucket {
        var remaining: Int
        var resetAt: ContinuousClock.Instant
    }

    private var buckets: [String: Bucket] = [:]
    /// Routes whose bucket hash Discord has told us. Two routes that share a
    /// bucket must share a budget, and Discord only reveals that through the
    /// `X-RateLimit-Bucket` header — so until a route has been called once, it
    /// is budgeted under its own key and merged afterwards.
    private var bucketByRoute: [String: String] = [:]
    /// A global 429 stops everything until it lifts. This is the one case where
    /// serialising is correct: the limit is on the account, not the route.
    private var globalResetAt: ContinuousClock.Instant?

    public init() {}

    /// Waits until this route may be called.
    public func acquire(route: String) async {
        while true {
            if let globalResetAt {
                let now = ContinuousClock.now
                if now < globalResetAt {
                    try? await Task.sleep(until: globalResetAt, clock: .continuous)
                    continue
                }
                self.globalResetAt = nil
            }

            let key = bucketByRoute[route] ?? route
            guard var bucket = buckets[key] else { return }

            if ContinuousClock.now >= bucket.resetAt {
                buckets[key] = nil
                return
            }
            if bucket.remaining > 0 {
                bucket.remaining -= 1
                buckets[key] = bucket
                return
            }
            try? await Task.sleep(until: bucket.resetAt, clock: .continuous)
        }
    }

    /// Records what a response said about the budget.
    public func update(route: String, headers: [AnyHashable: Any], statusCode: Int) {
        func header(_ name: String) -> String? {
            headers[name] as? String
                ?? headers[name.lowercased()] as? String
        }

        if let bucketHash = header("X-RateLimit-Bucket") {
            bucketByRoute[route] = bucketHash
        }
        let key = bucketByRoute[route] ?? route

        if statusCode == 429 {
            let isGlobal = header("X-RateLimit-Global").map { $0 == "true" } ?? false
            let retryAfter = header("Retry-After").flatMap(Double.init) ?? 1
            let resetAt = ContinuousClock.now.advanced(by: .seconds(retryAfter))
            if isGlobal {
                globalResetAt = resetAt
            } else {
                buckets[key] = Bucket(remaining: 0, resetAt: resetAt)
            }
            return
        }

        guard let remaining = header("X-RateLimit-Remaining").flatMap(Int.init),
              let resetAfter = header("X-RateLimit-Reset-After").flatMap(Double.init)
        else { return }

        // `Reset-After` is seconds from *now*, which is what makes it usable
        // without a synchronised clock — the absolute `X-RateLimit-Reset` is in
        // Discord's time and a Mac whose clock is a few seconds out would either
        // over-wait or over-send.
        buckets[key] = Bucket(
            remaining: remaining,
            resetAt: ContinuousClock.now.advanced(by: .seconds(resetAfter))
        )
    }

    /// Forgets everything. Called on sign-out, so a new account does not
    /// inherit the previous one's budgets.
    public func reset() {
        buckets.removeAll(keepingCapacity: false)
        bucketByRoute.removeAll(keepingCapacity: false)
        globalResetAt = nil
    }
}
