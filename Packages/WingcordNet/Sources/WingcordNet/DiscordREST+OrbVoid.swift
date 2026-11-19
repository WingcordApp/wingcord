import Foundation
import WingcordCore

/// The Void (`2026-10-orb-void`, docs/QUEUE-NOV19.md §2): Orbs thrown into it
/// are destroyed, and count towards its badge.
public struct OrbVoidStatus: Hashable, Sendable {
    public var balance: Int
    public var totalBurned: Int
    /// Whether the Void is open to this account right now.
    public var isEligible: Bool
    /// The most one batch may carry.
    public var maxBatchQuantity: Int

    public init(balance: Int, totalBurned: Int, isEligible: Bool, maxBatchQuantity: Int) {
        self.balance = balance
        self.totalBurned = totalBurned
        self.isEligible = isEligible
        self.maxBatchQuantity = maxBatchQuantity
    }
}

extension DiscordREST {
    private struct OrbVoidSnapshot: Decodable {
        var balance: Int?
        var total_burned: Int?
    }

    /// `GET /users/@me/virtual-currency/orb-void`.
    public func orbVoidStatus() async throws -> OrbVoidStatus {
        struct Answer: Decodable {
            var snapshot: OrbVoidSnapshot?
            var eligible: Bool?
            var max_batch_quantity: Int?
        }
        let answer = try await get(
            "/users/@me/virtual-currency/orb-void",
            route: "users/@me/virtual-currency/orb-void",
            as: Answer.self
        )
        return OrbVoidStatus(
            balance: answer.snapshot?.balance ?? 0,
            totalBurned: answer.snapshot?.total_burned ?? 0,
            isEligible: answer.eligible ?? false,
            maxBatchQuantity: answer.max_batch_quantity ?? 1
        )
    }

    /// `POST /users/@me/virtual-currency/orb-void`: one batch of throws, named
    /// by a fresh `sink_id` so a retry is never counted twice. Answers the
    /// balance and the total after it.
    public func throwOrbs(sinkID: String, quantity: Int, at timestamp: Date) async throws -> (balance: Int, totalBurned: Int) {
        struct Body: Encodable {
            var sink_id: String
            var quantity: Int
            var batch_timestamp: String
        }
        struct Answer: Decodable { var snapshot: OrbVoidSnapshot? }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let answer = try await post(
            "/users/@me/virtual-currency/orb-void",
            route: "users/@me/virtual-currency/orb-void",
            body: Body(sink_id: sinkID, quantity: quantity, batch_timestamp: formatter.string(from: timestamp)),
            as: Answer.self
        )
        return (answer.snapshot?.balance ?? 0, answer.snapshot?.total_burned ?? 0)
    }
}

extension DiscordREST.Failure {
    /// Worth sending again later — Discord's rule for a batch (`442928`): a
    /// server error, a rate limit or no answer at all.
    public var isRetryable: Bool {
        switch self {
        case .api(let status, _, _): status >= 500 || status == 429
        case .transport: true
        default: false
        }
    }
}
