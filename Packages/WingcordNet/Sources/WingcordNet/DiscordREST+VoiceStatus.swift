import Foundation
import WingcordCore

extension DiscordREST {
    /// Sets a voice channel's status — Discord's `updateVoiceChannelStatus`:
    /// `PUT /channels/{id}/voice-status` with `{status}`, answered 204. An
    /// empty status clears it, which is what Clear Channel Status sends.
    ///
    /// The new status reaches every client — this one included — as
    /// `VOICE_CHANNEL_STATUS_UPDATE`, which is what redraws it.
    public func setVoiceChannelStatus(_ status: String, in channelID: ChannelID) async throws {
        struct Body: Encodable { var status: String }
        _ = try await requestData(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/voice-status",
            route: "channels/{id}/voice-status",
            body: Body(status: status)
        )
    }
}
