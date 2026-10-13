import Foundation

// MARK: - The bitrate, moved by what the far end reports
//
// A stream's quality decides the band; this decides where in it the encoder
// sits right now. WebRTC's congestion controller has two halves, and the
// half this is — the loss-based one — is the half that works from receiver
// reports alone, which is everything an SFU's RTCP gives a client that does
// not read transport-wide feedback:
//
// - **Above ten per cent lost**, the path is congested and the rate drops by
//   half the loss: 20 % lost takes it to 90 % of what was being sent.
// - **Below two per cent**, there is room, and it climbs eight per cent a
//   second.
// - **In between**, it holds: some loss is the path, not the rate.
//
// The receiver's own estimate (REMB) is a ceiling over all of it. A window with
// no report holds too — silence is not evidence of anything.
//
// **What the path carries and what the encoder is told are kept apart.** The
// band moves whenever the server's want does, and a controller that kept only
// the clamped rate would forget, on every step down the ladder, a path it had
// already measured — and then climb back at eight per cent a second when the
// want returned. So the reports move a capacity, and the band only clamps it.

struct BitrateController: Sendable {
    /// What the path is believed to carry, in bits per second.
    private var capacity: Double
    private(set) var band: ClosedRange<Int>
    /// The rate the encoder was last told, so a change too small to matter is
    /// not a property write every half second.
    private var applied: Int

    /// No path is assumed to carry more than Discord's own ceiling for a call.
    private static let ceiling = 10_000_000.0

    /// What the encoder should be running at.
    var bitrate: Int { band.clamped(Int(capacity)) }

    /// Starts at the top of the band — Discord's camera does, and a share here
    /// does too; see `VideoQualityPolicy.shareBitrate`.
    init(quality: VideoQuality) {
        band = quality.bitrateMin...max(quality.bitrateMin, quality.bitrateMax)
        capacity = Double(band.upperBound)
        applied = band.upperBound
    }

    /// A new band — the want or the viewers moved.
    mutating func update(quality: VideoQuality) -> Int? {
        band = quality.bitrateMin...max(quality.bitrateMin, quality.bitrateMax)
        return settle()
    }

    /// One reporting window.
    ///
    /// - Parameters:
    ///   - fractionLost: the receiver's `fraction_lost` for this stream, out of
    ///     256, or `nil` when no report about it arrived.
    ///   - estimate: the receiver's bandwidth estimate in bits per second.
    ///   - interval: how long the window was.
    /// - Returns: the rate to give the encoder, when it moved enough to tell it.
    mutating func update(fractionLost: UInt8?, estimate: Int?, interval: Duration) -> Int? {
        if let fractionLost {
            let loss = Double(fractionLost) / 256
            if loss > 0.10 {
                // From what was sent, which is what was lost: a capacity above
                // the band was never tried.
                capacity = Double(bitrate) * (1 - 0.5 * loss)
            } else if loss < 0.02 {
                let seconds = Double(interval.components.seconds)
                    + Double(interval.components.attoseconds) / 1e18
                capacity *= pow(1.08, seconds)
            }
        }
        if let estimate { capacity = min(capacity, Double(estimate)) }
        capacity = min(capacity, Self.ceiling)
        return settle()
    }

    /// The rate, when it has moved by at least five per cent — or onto an edge
    /// of the band — since the encoder was last told.
    private mutating func settle() -> Int? {
        let rate = bitrate
        let moved = abs(Double(rate - applied)) / Double(max(applied, 1))
        let reachedEdge = rate != applied && (rate == band.lowerBound || rate == band.upperBound)
        guard moved >= 0.05 || reachedEdge else { return nil }
        applied = rate
        return rate
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
