import CryptoKit
import Foundation
import Synchronization

// MARK: - The two ends of the frame transform
//
// `DAVEEncryptor` sits between the encoder and the packetizer; `DAVEDecryptor`
// sits between the depacketizer and the decoder. Both are `Sendable` classes
// with their own lock, like the rest of this package's data plane, and both are
// called synchronously from whichever real-time thread produced or received the
// media — §1.5 of `INVARIANTS.md`: an `await` between a microphone and a socket
// is jitter this client would be adding.
//
// **Passthrough is a real state, not an error state.** A call can be running
// with no DAVE at all (a stage channel, or a transition in progress), and in
// that state frames go through untouched. What must never happen is a frame
// leaving *encrypted* when the far end is not expecting one, or leaving *clear*
// when the session is meant to be end-to-end encrypted — so passthrough is set
// by the transition state machine and by nothing else.

/// The send side.
final class DAVEEncryptor: Sendable {
    private struct State {
        var ratchet: MLSHashRatchet?
        var passthrough = true
        /// The counter. **Starts at one**, because it is pre-incremented before
        /// every frame — a frame is never sent under nonce zero.
        var nonce: UInt32 = 0
        var generation: UInt32 = 0
        var key: SymmetricKey?
        var frame = OutboundFrame()
        var scratch: [UInt8] = []
    }

    private let state = Mutex(State())

    /// Adopts a new epoch's ratchet. The counter restarts, which is safe
    /// precisely because the key is new.
    func setRatchet(_ ratchet: MLSHashRatchet?) {
        state.withLock {
            $0.ratchet = ratchet
            $0.nonce = 0
            $0.generation = 0
            $0.key = nil
        }
    }

    func setPassthrough(_ passthrough: Bool) {
        state.withLock { $0.passthrough = passthrough }
    }

    var isPassthrough: Bool { state.withLock { $0.passthrough } }

    /// Transforms one encoded frame, or returns it untouched in passthrough.
    ///
    /// Returns `nil` when the frame cannot be protected — no ratchet, or ten
    /// attempts at an H.264 frame whose ciphertext kept containing a start
    /// code. Dropping is the only correct answer: sending it in the clear would
    /// silently break the guarantee the call is claiming.
    func encrypt(_ frame: [UInt8], codec: DAVECodecKind) -> [UInt8]? {
        state.withLock { state in
            if state.passthrough { return frame }
            guard state.ratchet != nil else {
                VoiceTrace.note(.sendUnkeyed)
                return nil
            }

            DAVECodec.process(frame, codec: codec, into: &state.frame)
            let aad = state.frame.clearBytes
            let plaintext = state.frame.mediaBytes
            let rangesSize = state.frame.rangesSize

            // Up to ten attempts, each with a fresh nonce. Only H.264 can fail
            // the check, and only rarely — but a frame that keeps failing is
            // one the far end could never reassemble.
            for _ in 0..<10 {
                state.nonce &+= 1
                let nonce = state.nonce
                let generation = DAVE.generation(of: nonce)
                if state.key == nil || generation != state.generation {
                    guard let key = state.ratchet?.key(for: generation) else {
                        VoiceTrace.note(.sendUnkeyed)
                        return nil
                    }
                    state.key = SymmetricKey(data: key)
                    state.generation = generation
                }
                guard let key = state.key else {
                    VoiceTrace.note(.sendUnkeyed)
                    return nil
                }

                guard let sealed = try? DAVECipher.seal(
                    plaintext: plaintext,
                    key: key,
                    nonce: DAVE.fullNonce(from: nonce),
                    authenticating: aad
                ) else {
                    VoiceTrace.note(.sendFailed)
                    return nil
                }

                // Built straight into the scratch buffer and returned from it:
                // one array per frame reaches the packetizer either way, and
                // assembling it in a second buffer first would double that for
                // nothing.
                state.frame.reconstruct(ciphertext: sealed.ciphertext, into: &state.scratch)
                state.scratch.append(contentsOf: sealed.tag)
                LEB128.write(UInt64(nonce), into: &state.scratch)
                for range in state.frame.ranges {
                    LEB128.write(UInt64(range.offset), into: &state.scratch)
                    LEB128.write(UInt64(range.size), into: &state.scratch)
                }
                let supplemental = DAVE.minimumSupplementalBytes
                    + LEB128.size(UInt64(nonce)) + rangesSize
                guard supplemental <= Int(UInt8.max) else {
                    VoiceTrace.note(.sendFailed)
                    return nil
                }
                state.scratch.append(UInt8(supplemental))
                state.scratch.append(contentsOf: DAVE.magicMarker)

                if DAVECodec.encryptedFrameIsSafe(
                    state.scratch, ranges: state.frame.ranges, codec: codec
                ) {
                    return state.scratch
                }
            }
            VoiceTrace.note(.sendFailed)
            return nil
        }
    }
}

// MARK: - The receive side

/// One sender's keys for one epoch, and the replay window over them.
///
/// A separate object per epoch because a transition keeps the previous one
/// alive for ten seconds: media that was in flight when the group changed was
/// encrypted under the old ratchet and arrives after the change.
private final class RatchetWindow {
    var ratchet: MLSHashRatchet
    var keys: [UInt32: (key: SymmetricKey, expiry: Date?)] = [:]
    var oldestGeneration: UInt32 = 0
    var newestGeneration: UInt32 = 0
    var newestNonce: UInt64?
    /// Nonces below the high-water mark that have not been seen yet, so a
    /// reordered frame is still accepted exactly once.
    var missingNonces: [UInt64] = []
    var expiry: Date?
    let created = Date()

    init(ratchet: MLSHashRatchet) { self.ratchet = ratchet }

    /// Whether this nonce may be processed, or is a replay.
    func admits(generation: UInt32, nonce: UInt32) -> Bool {
        guard let newest = newestNonce else { return true }
        let wrapped = DAVE.wrappedNonce(generation: generation, truncated: nonce)
        return wrapped > newest || missingNonces.contains(wrapped)
    }

    func recordSuccess(generation: UInt32, nonce: UInt32, now: Date) {
        let wrapped = DAVE.wrappedNonce(generation: generation, truncated: nonce)
        if let newest = newestNonce {
            if wrapped > newest {
                // Everything skipped over is remembered so it can still arrive.
                let gap = min(wrapped - newest - 1, UInt64(DAVE.maximumMissingNonces))
                while !missingNonces.isEmpty,
                      missingNonces.count + Int(gap) > DAVE.maximumMissingNonces {
                    missingNonces.removeFirst()
                }
                if gap > 0 {
                    for value in (wrapped - gap)..<wrapped { missingNonces.append(value) }
                }
                newestNonce = wrapped
            } else if let index = missingNonces.firstIndex(of: wrapped) {
                missingNonces.remove(at: index)
            }
        } else {
            newestNonce = wrapped
        }

        guard generation > newestGeneration, keys[generation] != nil else { return }
        newestGeneration = generation
        // Once a newer generation is in use, the older ones are on the clock.
        let deadline = now.addingTimeInterval(DAVE.keyRetention)
        for (value, entry) in keys where value < newestGeneration {
            keys[value] = (entry.key, min(entry.expiry ?? deadline, deadline))
        }
    }

    func key(for generation: UInt32, now: Date) -> SymmetricKey? {
        purge(now)
        guard generation >= oldestGeneration else { return nil }
        guard generation <= newestGeneration &+ DAVE.maximumGenerationGap else { return nil }

        // A sender cannot have produced more generations than the ratchet has
        // been alive to produce. Fifty audio frames and two 60 fps video
        // streams is the ceiling Discord's own client uses, and it turns a
        // wild generation into a rejection rather than a long derivation.
        let lifetime = now.timeIntervalSince(created)
        let maximumFrames = UInt64((50.0 + 2 * 60.0) * max(lifetime, 0))
        guard UInt64(generation) <= maximumFrames >> UInt64(DAVE.generationShift) else {
            return nil
        }

        if let existing = keys[generation] { return existing.key }
        guard let material = ratchet.key(for: generation) else { return nil }
        // A generation that arrives out of order is already stale, so it is
        // created with an expiry rather than an open-ended life.
        let expiry = generation < newestGeneration
            ? now.addingTimeInterval(DAVE.keyRetention) : nil
        let key = SymmetricKey(data: material)
        keys[generation] = (key, expiry)
        return key
    }

    private func purge(_ now: Date) {
        keys = keys.filter { $0.value.expiry.map { $0 > now } ?? true }
        while oldestGeneration < newestGeneration, keys[oldestGeneration] == nil {
            ratchet.erase(oldestGeneration)
            oldestGeneration += 1
        }
    }
}

/// The receive side, for one remote sender.
final class DAVEDecryptor: Sendable {
    /// Whose media this opens, and the id the base secret was exported under.
    ///
    /// Carried only so a failure can say it out loud: every step of the key
    /// derivation matches Discord's published library, so the thing left worth
    /// checking is whether the *value* fed into it is the snowflake we think.
    let userID: UInt64

    init(userID: UInt64) { self.userID = userID }

    private struct State {
        /// Newest last. A frame is tried against the newest first, because in
        /// steady state that is the one that works.
        var windows: [RatchetWindow] = []
        var passthroughUntil: Date = .distantPast
        var scratch: [UInt8] = []
        /// Whether the first frame of each failure kind has described itself.
        /// **Once, not per frame** — this runs fifty times a second, and a
        /// description repeated at that rate is noise that buries the handshake
        /// lines above it.
        var hasReportedUnparsed = false
        var hasReportedRefused = false
    }

    private let state = Mutex(State())

    /// Adopts a new epoch's ratchet, putting the previous one on a timer.
    func transition(to ratchet: MLSHashRatchet?, retaining window: TimeInterval) {
        state.withLock { state in
            let deadline = Date().addingTimeInterval(window)
            for existing in state.windows {
                existing.expiry = min(existing.expiry ?? deadline, deadline)
            }
            if let ratchet { state.windows.append(RatchetWindow(ratchet: ratchet)) }
        }
    }

    /// Turns passthrough on indefinitely, or schedules it off after `window`.
    func setPassthrough(_ passthrough: Bool, retaining window: TimeInterval) {
        state.withLock { state in
            if passthrough {
                state.passthroughUntil = .distantFuture
            } else {
                state.passthroughUntil = min(
                    state.passthroughUntil, Date().addingTimeInterval(window)
                )
            }
        }
    }

    func reset() {
        state.withLock { state in
            state.windows.removeAll()
            state.passthroughUntil = .distantPast
        }
    }

    /// Recovers one encoded frame, or returns `nil` if it cannot be trusted.
    func decrypt(_ frame: [UInt8], isAudio: Bool) -> [UInt8]? {
        // The SFU synthesises this exact packet for a muted source. It is not a
        // protocol frame and never will be, and refusing it would mean a decoder
        // starved every time somebody mutes.
        if isAudio, frame == DAVE.opusSilence { return frame }

        let now = Date()
        return state.withLock { state in
            state.windows.removeAll { $0.expiry.map { $0 < now } ?? false }

            guard let parsed = InboundFrame(parsing: frame) else {
                // Not a protocol frame. Only a session that is deliberately in
                // passthrough may let one through; otherwise it is a frame from
                // somebody who should be encrypting and is not.
                if state.passthroughUntil > now { return frame }
                VoiceTrace.note(.receiveUnparsed)
                if !state.hasReportedUnparsed {
                    state.hasReportedUnparsed = true
                    VoiceTrace.fault(
                        "dave frame has no readable footer: \(frame.count) bytes, "
                        + "tail=\(Self.hex(frame.suffix(12)))"
                    )
                }
                return nil
            }

            let generation = DAVE.generation(of: parsed.truncatedNonce)
            let nonce = DAVE.fullNonce(from: parsed.truncatedNonce)

            // Newest window first: in steady state the first one works.
            for window in state.windows.reversed() {
                let wrapped = DAVE.wrappedGeneration(
                    oldest: window.oldestGeneration, generation: generation
                )
                guard window.admits(generation: wrapped, nonce: parsed.truncatedNonce),
                      let key = window.key(for: wrapped, now: now),
                      let plaintext = DAVECipher.open(
                          ciphertext: parsed.ciphertext,
                          tag: parsed.tag,
                          key: key,
                          nonce: nonce,
                          authenticating: parsed.authenticated
                      )
                else { continue }

                window.recordSuccess(
                    generation: wrapped, nonce: parsed.truncatedNonce, now: now
                )
                parsed.reconstruct(plaintext: plaintext, into: &state.scratch)
                return state.scratch
            }

            VoiceTrace.note(.receiveRefused)
            if !state.hasReportedRefused {
                state.hasReportedRefused = true
                // The footer parsed, so the layout is right and the key is not.
                // Everything needed to tell which half is wrong goes in one
                // line: what the sender said, and what we were holding.
                VoiceTrace.fault(
                    "dave frame parsed but no key opened it: sender=\(userID) "
                    + "gen=\(generation) "
                    + "nonce=\(parsed.truncatedNonce) windows=\(state.windows.count) "
                    + "oldest=\(state.windows.first?.oldestGeneration ?? 0) "
                    + "newest=\(state.windows.last?.newestGeneration ?? 0) "
                    + "cipher=\(parsed.ciphertext.count)B aad=\(parsed.authenticated.count)B "
                    + "ranges=\(parsed.ranges.count)"
                )
            }
            return nil
        }
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
