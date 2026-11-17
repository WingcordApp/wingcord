import Foundation

/// The numbers behind "Voice Connected", for the connection panel
/// (docs/ACTIVITIES-CALLS-PICKER.md, decision 11): both directions, as
/// Discord's own panel shows them.
///
/// **Its own value on the model**, updated twice a second while a call runs:
/// only the open panel reads it, so the call surfaces don't redraw with it.
struct CallDiagnostics: Hashable, Sendable {
    /// The voice server's heartbeat round trip.
    var pingMilliseconds: Int?
    /// What this end loses of everybody else.
    var inboundLossPercent = 0
    /// What the far end loses of us, from its reports.
    var outboundLossPercent = 0
    var jitterMilliseconds: Double = 0
    var outgoingKilobits = 0
    /// The transport cipher, as the server named it.
    var transportEncryption: String?

    static let idle = CallDiagnostics()

    /// The cipher in words.
    var transportName: String? {
        switch transportEncryption {
        case "aead_aes256_gcm_rtpsize": "AES-256-GCM"
        case "aead_xchacha20_poly1305_rtpsize": "XChaCha20-Poly1305"
        case let other: other
        }
    }
}
