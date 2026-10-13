import OSLog
import Synchronization

// MARK: - What the voice stack says about itself
//
// One sink for the whole package, installed once at launch and `nil` in every
// build nobody asked to trace. It exists because **every way this stack fails
// is silent**: a handshake that stops advancing, a group that never
// establishes, and a call that connects and carries no sound all present as
// the same thing — a window with a control bar under it and nothing happening.
//
// Two kinds of line, and the split is the whole design:
//
// - **Events** — the DAVE handshake is nine messages in a fixed order, and
//   reading which one it stopped after is the diagnosis. One line each,
//   formatted only when a sink is installed.
// - **Drops** — a frame the transform refused. Those arrive fifty times a
//   second per stream, so they are *counted* and flushed with each session's
//   media line. A line each would cost more than the media path
//   it is measuring, and would bury the nine lines that say why.
//
// Free when off. `write` takes an autoclosure, so no message is built; `note`
// checks the sink before it touches an atomic, so the real-time threads pay one
// predictable branch on a null pointer.
public enum VoiceTrace {
    /// Where the lines go, or `nil` for the builds nobody is watching.
    ///
    /// **Installed once, in `WingcordApp.init`, before a call can exist**, and
    /// never moved afterwards — which is what makes reading it from the audio
    /// and network threads safe without a lock.
    public nonisolated(unsafe) static var sink: (@Sendable (String) -> Void)?

    /// Whether anything is listening.
    static var isOn: Bool { sink != nil }

    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Voice")

    /// Records one line.
    static func write(_ message: @autoclosure () -> String) {
        guard let sink else { return }
        sink(message())
    }

    /// Records one failure, to the trace **and** to the unified log.
    ///
    /// Both, because they answer different questions. The trace file is what a
    /// reader tails while reproducing something; the unified log is what still
    /// holds the reason in a session nobody thought to trace beforehand — which
    /// is every session where the fault happened once.
    ///
    /// The string is always built. That is affordable precisely because these
    /// are faults: on a healthy call there are none, and on a broken one the
    /// cost of a `String` is not what broke it.
    static func fault(_ message: @autoclosure () -> String) {
        let text = message()
        log.error("\(text, privacy: .public)")
        sink?(text)
    }

    // MARK: Frames the transform refused

    /// Why a frame did not make it through.
    ///
    /// **Four counts, not one.** They are four different diagnoses and
    /// collapsing them would lose the only thing the number is for: an unkeyed
    /// drop is a handshake that has not finished, and a refused one is a
    /// handshake that finished and left the two ends disagreeing about the key.
    enum Drop {
        /// Nothing to encrypt under — the group has not established, or the
        /// ratchet would not yield a key for this generation.
        case sendUnkeyed
        /// Keyed, and the frame still could not be protected: a seal that
        /// failed, supplemental data too large for the single byte that
        /// measures it, or ten attempts at an H.264 frame that each left a
        /// start code in the ciphertext. Never seen on Opus.
        case sendFailed
        /// A sender whose ratchet has not arrived. Their media is dropped
        /// rather than played, because a missing key is not plaintext.
        case receiveUnkeyed
        /// A frame that is not a DAVE protocol frame at all: no magic marker,
        /// or a footer that will not parse. Distinct from `receiveRefused`
        /// because it points at the frame LAYOUT rather than at the key.
        case receiveUnparsed
        /// A frame that parsed and then would not open: a replay, a forgery,
        /// or a key the two ends derived differently.
        case receiveRefused
        /// A datagram whose RTP header would not parse at all.
        case transportUnparsed
        /// A datagram the **transport** cipher would not open. A different
        /// failure from `receiveRefused` and one layer below it: this is the
        /// session key from opcode 4, not DAVE — so it means the cipher, the
        /// key, or the length of the clear prefix used as associated data.
        case transportRefused
    }

    private static let sendUnkeyed = Atomic<Int>(0)
    private static let sendFailed = Atomic<Int>(0)
    private static let receiveUnkeyed = Atomic<Int>(0)
    private static let receiveUnparsed = Atomic<Int>(0)
    private static let receiveRefused = Atomic<Int>(0)
    private static let transportUnparsed = Atomic<Int>(0)
    private static let transportRefused = Atomic<Int>(0)

    /// Counts one dropped frame. Called from the real-time threads.
    static func note(_ drop: Drop) {
        guard isOn else { return }
        switch drop {
        case .sendUnkeyed: sendUnkeyed.add(1, ordering: .relaxed)
        case .sendFailed: sendFailed.add(1, ordering: .relaxed)
        case .receiveUnkeyed: receiveUnkeyed.add(1, ordering: .relaxed)
        case .receiveUnparsed: receiveUnparsed.add(1, ordering: .relaxed)
        case .receiveRefused: receiveRefused.add(1, ordering: .relaxed)
        case .transportUnparsed: transportUnparsed.add(1, ordering: .relaxed)
        case .transportRefused: transportRefused.add(1, ordering: .relaxed)
        }
    }

    /// Writes what was dropped since the last call, and clears the counts.
    ///
    /// Silent when nothing was dropped, so a healthy call adds no lines at all
    /// and the ones it does add stay worth reading.
    ///
    /// **The counts cover every session at once, and the line says so.** These
    /// are static atomics read from the real-time threads, where a per-session
    /// lookup would be a cost on the one path that cannot afford one — so a
    /// call, a share it publishes and a share it watches all add into the same
    /// numbers, and two of them race to flush. A reader who takes `dropped 10
    /// ours unkeyed` for the session whose line it happens to sit under will
    /// diagnose the wrong one; naming it is cheaper than either the lie or the
    /// refactor.
    static func flushDrops() {
        guard isOn else { return }
        let unkeyed = sendUnkeyed.exchange(0, ordering: .relaxed)
        let failed = sendFailed.exchange(0, ordering: .relaxed)
        let theirs = receiveUnkeyed.exchange(0, ordering: .relaxed)
        let unparsed2 = receiveUnparsed.exchange(0, ordering: .relaxed)
        let refused = receiveRefused.exchange(0, ordering: .relaxed)
        let unparsed = transportUnparsed.exchange(0, ordering: .relaxed)
        let unopenable = transportRefused.exchange(0, ordering: .relaxed)
        guard unkeyed + failed + theirs + unparsed2 + refused + unparsed + unopenable > 0
        else { return }

        var parts: [String] = []
        parts.reserveCapacity(6)
        if unkeyed > 0 { parts.append("\(unkeyed) ours unkeyed") }
        if failed > 0 { parts.append("\(failed) ours unprotectable") }
        if theirs > 0 { parts.append("\(theirs) theirs unkeyed") }
        if unparsed2 > 0 { parts.append("\(unparsed2) theirs not a DAVE frame") }
        if refused > 0 { parts.append("\(refused) theirs refused") }
        if unparsed > 0 { parts.append("\(unparsed) not RTP") }
        if unopenable > 0 { parts.append("\(unopenable) transport would not open") }
        write("dropped, across every session: " + parts.joined(separator: ", "))
    }
}
