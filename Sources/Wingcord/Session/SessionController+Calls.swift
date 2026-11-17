import Foundation
import WingcordCore
import WingcordNet

// MARK: - Calls already going

extension SessionController {
    /// Asks the gateway whether a private channel has a call going (op 13).
    ///
    /// **Discord's rule** (CallStore, module 470710): on a new connection and
    /// on a resume for the open conversation, and the first time a
    /// conversation is opened; never for a server channel. The answer is
    /// `CALL_CREATE` with the people in it, which the call lobby draws.
    func askForCall(in channelID: ChannelID, force: Bool = false) {
        guard !LaunchOptions.current.usesDemoFixtures,
              let channel = model.channelIndex[channelID],
              channel.kind == .directMessage || channel.kind == .groupDirectMessage
        else { return }
        guard force || callsAsked.insert(channelID).inserted else { return }
        callsAsked.insert(channelID)
        Task { [socket] in await socket?.callConnect(channelID: channelID) }
    }
}
