import Foundation
import Testing
@testable import WingcordNet

/// A bucket is Discord's hash **per top-level resource** (docs/BETA3.md
/// §1.10): the same `X-RateLimit-Bucket` comes back for every channel's
/// history, and each channel has its own budget behind it.
@Suite("Rate limit buckets")
struct RateLimiterBucketTests {
    private static func exhausted(bucket: String) -> [AnyHashable: Any] {
        ["X-RateLimit-Bucket": bucket, "X-RateLimit-Remaining": "0", "X-RateLimit-Reset-After": "3"]
    }

    /// Channel 2 learns the hash with budget to spare; channel 1, same hash,
    /// spends its own. Keyed by the hash alone, channel 2 then waited out
    /// channel 1's reset.
    @Test("Two channels' history do not share a budget")
    func channelsAreSeparate() async {
        let limiter = RateLimiter()
        await limiter.update(
            route: "channels/2/messages",
            headers: ["X-RateLimit-Bucket": "abc", "X-RateLimit-Remaining": "4", "X-RateLimit-Reset-After": "3"],
            statusCode: 200
        )
        await limiter.update(route: "channels/1/messages", headers: Self.exhausted(bucket: "abc"), statusCode: 200)
        let started = ContinuousClock.now
        await limiter.acquire(route: "channels/2/messages")
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("The key is the hash and the resource")
    func keyNamesTheResource() async {
        let limiter = RateLimiter()
        await limiter.update(route: "channels/1/messages", headers: Self.exhausted(bucket: "abc"), statusCode: 200)
        #expect(await limiter.bucketKey(for: "channels/1/messages") == "abc:channels/1")
        #expect(RateLimiter.majorParameter(of: "guilds/9/members/@me") == "guilds/9")
        #expect(RateLimiter.majorParameter(of: "users/{id}/profile").isEmpty)
        // A route never answered is its own key, as before.
        #expect(await limiter.bucketKey(for: "channels/3/messages") == "channels/3/messages")
    }
}
