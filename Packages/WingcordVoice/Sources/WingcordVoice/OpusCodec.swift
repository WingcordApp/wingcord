import COpus
import COpusShim
import Foundation

// MARK: - Opus
//
// Discord's voice channel is Opus and nothing else — there is no second codec
// to fall back to and no negotiation to lose. CoreAudio ships no Opus at all,
// which is why this is the one part of the stack the platform could not supply.
//
// **Every constant here is Discord's, not a choice.** 48 kHz, stereo, and a
// 20 ms frame — 960 samples per channel — because that is what the server's
// mixer expects and what every other client sends. A 10 ms frame halves the
// latency and doubles the packet rate, which on a busy channel is the fastest
// way to be rate limited off it.

public enum OpusFormat {
    public static let sampleRate: Int32 = 48_000
    public static let channels: Int32 = 2
    /// Samples **per channel** in one packet.
    public static let frameSize: Int32 = 960
    /// What the RTP clock advances by per packet. The clock is per-channel, so
    /// it is the frame size rather than the interleaved sample count.
    public static let clockAdvance: UInt32 = 960
    /// Interleaved `Int16` count in one frame.
    public static var interleavedCount: Int { Int(frameSize * channels) }
    /// The largest packet worth allocating for. Opus tops out well below this
    /// at any bitrate this app uses; the headroom costs one page.
    public static let maximumPacketBytes = 1_275
}

public enum OpusFailure: Error, Sendable {
    case create(Int32)
    case encode(Int32)
    case decode(Int32)
}

/// The outgoing half.
///
/// Not `Sendable`: it holds a C encoder whose state is mutated per frame, and it
/// is owned by exactly one thing — the audio path. Handing it across an actor
/// boundary is the bug this refusal prevents.
public final class OpusEncoder {
    private let state: OpaquePointer

    /// - Parameter bitrate: bits per second. Discord's channels publish a
    ///   ceiling per guild — 64k unboosted, up to 384k boosted — and the server
    ///   simply drops what exceeds it, so the caller passes the channel's own
    ///   number rather than a constant.
    public init(bitrate: Int32) throws {
        var error: Int32 = 0
        guard let state = opus_encoder_create(
            OpusFormat.sampleRate,
            OpusFormat.channels,
            OPUS_APPLICATION_VOIP,
            &error
        ), error == OPUS_OK else {
            throw OpusFailure.create(error)
        }
        self.state = state

        set(OPUS_SET_BITRATE_REQUEST, bitrate)
        // **In-band forward error correction, and it is the whole answer to
        // packet loss.** With FEC on, every packet carries a low-bitrate copy of
        // the *previous* frame; a decoder that misses one recovers it from the
        // next arrival instead of concealing it. It costs a few per cent of
        // bitrate and it is the single largest quality lever on a lossy path.
        //
        // It does nothing on its own: Opus only spends bits on the redundant
        // copy in proportion to the loss it is told to expect, so
        // `PACKET_LOSS_PERC` has to be fed from what the receiver is actually
        // seeing. `updateExpectedLoss` is that feedback, and without it FEC is
        // a flag that is on and inert.
        set(OPUS_SET_INBAND_FEC_REQUEST, 1)
        set(OPUS_SET_PACKET_LOSS_PERC_REQUEST, 5)
        // Discontinuous transmission: silence is not sent at all. Together with
        // the app's own gate this is what keeps an idle channel of eight people
        // from being eight streams of encoded room tone.
        set(OPUS_SET_DTX_REQUEST, 1)
        set(OPUS_SET_SIGNAL_REQUEST, OPUS_SIGNAL_VOICE)
        // Full band. The default is already this at 48 kHz; naming it means a
        // future bitrate change cannot quietly narrow the band instead.
        set(OPUS_SET_BANDWIDTH_REQUEST, OPUS_BANDWIDTH_FULLBAND)
        set(OPUS_SET_COMPLEXITY_REQUEST, 9)
    }

    deinit { opus_encoder_destroy(state) }

    /// Re-arms FEC for the loss the far end is reporting.
    ///
    /// Clamped, because a spike to 100 makes Opus spend most of the bitrate on
    /// redundancy and the primary signal collapses — the cure being worse than
    /// the disease is the failure mode this bound exists for.
    public func updateExpectedLoss(percent: Int) {
        set(OPUS_SET_PACKET_LOSS_PERC_REQUEST, Int32(min(30, max(0, percent))))
    }

    public func setBitrate(_ bitrate: Int32) {
        set(OPUS_SET_BITRATE_REQUEST, bitrate)
    }

    /// Encodes one 20 ms interleaved stereo frame.
    ///
    /// The output buffer is owned by the encoder and reused, so the caller must
    /// consume it before the next call. That is what keeps the audio path free
    /// of a per-packet allocation at fifty packets a second.
    public func encode(_ pcm: UnsafePointer<Int16>, into output: inout [UInt8]) throws -> Int {
        let written = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return OPUS_BUFFER_TOO_SMALL }
            return opus_encode(state, pcm, OpusFormat.frameSize, base, Int32(buffer.count))
        }
        guard written > 0 else { throw OpusFailure.encode(written) }
        return Int(written)
    }
}

/// The incoming half — one per speaker.
///
/// A decoder carries the state of one stream: its band, its gain, and the
/// history the concealer extrapolates from. Sharing one across speakers makes
/// every concealment sound like whoever spoke last.
public final class OpusDecoder {
    private let state: OpaquePointer

    public init() throws {
        var error: Int32 = 0
        guard let state = opus_decoder_create(
            OpusFormat.sampleRate,
            OpusFormat.channels,
            &error
        ), error == OPUS_OK else {
            throw OpusFailure.create(error)
        }
        self.state = state
    }

    deinit { opus_decoder_destroy(state) }

    /// Decodes one packet into `pcm`, which must hold
    /// `OpusFormat.interleavedCount` samples.
    ///
    /// - Parameter packet: nil for a packet that never arrived. Opus then runs
    ///   its concealer, which extrapolates the pitch and the spectral envelope
    ///   of what it last decoded — audibly better than a gap, and free.
    /// - Parameter recoverFromFEC: pass true when the *next* packet has already
    ///   arrived and carries a redundant copy of this one. This is the path that
    ///   makes a loss inaudible rather than merely smoothed, and it needs the
    ///   caller to hold one packet of delay to use it at all — which is the
    ///   whole design of the jitter buffer above.
    @discardableResult
    public func decode(
        _ packet: [UInt8]?,
        recoverFromFEC: Bool = false,
        into pcm: UnsafeMutablePointer<Int16>
    ) throws -> Int {
        let written: Int32
        if let packet {
            written = packet.withUnsafeBufferPointer { buffer -> Int32 in
                opus_decode(
                    state,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    pcm,
                    OpusFormat.frameSize,
                    recoverFromFEC ? 1 : 0
                )
            }
        } else {
            written = opus_decode(state, nil, 0, pcm, OpusFormat.frameSize, 0)
        }
        guard written > 0 else { throw OpusFailure.decode(written) }
        return Int(written)
    }
}

// MARK: - `opus_encoder_ctl` without the varargs

extension OpusEncoder {
    /// One setter for every request in `opus_defines.h`, through the C shim.
    ///
    /// Swift cannot call a C variadic without a `va_list` form and Opus
    /// publishes none, so `COpusShim` supplies the two non-variadic shapes the
    /// whole surface actually has. Failures are ignored on purpose: every
    /// request here is a tuning knob with a working default, and an encoder
    /// that refused to construct would already have thrown above.
    fileprivate func set(_ request: Int32, _ value: Int32) {
        _ = wc_opus_encoder_set(state, request, value)
    }
}
