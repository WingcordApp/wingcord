import Foundation
import Testing
@testable import WingcordNet

/// A live handshake against Discord's gateway, with no credentials.
///
/// **HELLO arrives before IDENTIFY**, so the entire transport — the WebSocket
/// handshake, the `zlib-stream` framing, the shared inflate context and the
/// envelope decoder — can be proved end to end without an account.
///
/// Then IDENTIFY is sent with a deliberately invalid token. Discord answers a
/// received-but-rejected IDENTIFY by closing with **4004**. That single fact is
/// what distinguishes the two failure modes that look identical from the
/// outside:
///
///   - a close arrives → the frame reached Discord, and any later problem is in
///     what was sent
///   - nothing arrives → the frame was *ignored*, which is what happens when
///     JSON payloads are sent as binary frames instead of text
///
/// Gated behind an environment variable: it needs the network, so it must never
/// run as part of an ordinary suite where a flight-mode failure would look like
/// a code regression.
///
/// ```sh
/// WINGCORD_LIVE=1 swift test --package-path Packages/WingcordNet
/// ```
@Suite(
    "Gateway live smoke",
    .enabled(if: ProcessInfo.processInfo.environment["WINGCORD_LIVE"] == "1")
)
struct GatewayLiveSmokeTests {

    @Test("HELLO arrives, and a rejected IDENTIFY is answered rather than ignored", .timeLimit(.minutes(1)))
    func handshake() async throws {
        let socket = GatewaySocket()
        var sawConnecting = false
        var outcome: String?

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(25))
            await socket.stop()
        }

        await socket.connect(token: "not.a.real.token")
        guard let stream = await socket.events else {
            Issue.record("no event stream")
            return
        }

        for await event in stream {
            switch event {
            case .connecting:
                sawConnecting = true
            case .authenticationFailed:
                // Discord read the IDENTIFY and rejected the token. The
                // transport works.
                outcome = "rejected"
            case .disconnected(let reason, _):
                outcome = outcome ?? "disconnected: \(reason)"
            case .ready:
                outcome = "ready"
            default:
                break
            }
            if outcome != nil { break }
        }

        watchdog.cancel()
        await socket.stop()

        #expect(sawConnecting)
        // Anything but silence. A nil outcome means the socket opened, HELLO was
        // either never received or never acted on, and nothing came back — which
        // is the exact shape of a client whose payloads Discord is discarding.
        #expect(outcome != nil, "the gateway never answered — payloads are being ignored")
    }
}
