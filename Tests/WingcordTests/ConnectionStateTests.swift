import Testing
@testable import Wingcord
import WingcordCore

/// What the socket opening does to the window's connection state.
///
/// **The reconnect row is the one that matters.** It used to answer
/// `connecting`, which took the workspace and the window's toolbar down for the
/// length of every reconnect — see `ConnectionState.onSocketOpening`.
@MainActor
struct ConnectionStateTests {

    @Test("A reconnect stays a reconnect, and the workspace stays up through it")
    func reconnectKeepsTheWorkspace() {
        let state = AppModel.ConnectionState.reconnecting.onSocketOpening()
        #expect(state == .reconnecting)

        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        model.connectionState = state
        #expect(model.showsWorkspace)
    }

    @Test("A session that is up is not taken down by the socket opening")
    func readyStaysReady() {
        #expect(AppModel.ConnectionState.ready.onSocketOpening() == .ready)
    }

    @Test("A first connection, or one after a failure, is connecting")
    func freshConnectionsConnect() {
        #expect(AppModel.ConnectionState.signedOut.onSocketOpening() == .connecting)
        #expect(AppModel.ConnectionState.connecting.onSocketOpening() == .connecting)
        #expect(AppModel.ConnectionState.failed("gone").onSocketOpening() == .connecting)
    }
}
