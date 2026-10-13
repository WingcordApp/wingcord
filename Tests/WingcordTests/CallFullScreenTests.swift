import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Discord's Full Screen for a call, and what it may and may not do to the
/// window and to Escape.
@MainActor
@Suite("Call full screen")
struct CallFullScreenTests {

    @Test("Without a call there is nothing to give the screen to")
    func needsACall() {
        let model = AppModel()
        model.enterCallFullScreen()
        #expect(!model.isCallFullScreen)
    }

    /// The bottom of the stack: a profile opened from a tile is above it and
    /// takes Escape first; with nothing over it, Escape is the call's.
    @Test("Escape leaves it, unless something opened over it")
    func escapeOrder() {
        let model = AppModel()
        model.connectedVoiceChannelID = ChannelID(rawValue: 42)
        model.enterCallFullScreen()
        #expect(model.isCallFullScreen)
        #expect(model.escapeLayer == .callFullScreen)
        #expect(!model.isCovered(.callFullScreen))

        model.profileRequest = ProfileRequest(userID: UserID(rawValue: 7), anchor: .zero)
        #expect(model.escapeLayer == .profile)
        #expect(model.isCovered(.callFullScreen))
    }

    /// The window left full screen by the system's own control: the call goes
    /// back into the workspace, and nothing is left believing it owns the
    /// window.
    @Test("Leaving full screen from the system ends it")
    func systemExit() {
        let model = AppModel()
        model.connectedVoiceChannelID = ChannelID(rawValue: 42)
        model.enterCallFullScreen()
        model.callFullScreenTookWindow = true
        model.callFullScreenWindowDidExit()
        #expect(!model.isCallFullScreen)
        #expect(!model.callFullScreenTookWindow)
        #expect(model.escapeLayer == nil)
    }
}
