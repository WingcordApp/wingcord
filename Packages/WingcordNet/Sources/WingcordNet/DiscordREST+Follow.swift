import Foundation
import WingcordCore

extension DiscordREST {
    /// Follows an announcement channel into a channel of the reader's own:
    /// Discord's `POST /channels/{id}/followers` with `webhook_channel_id`,
    /// which makes a webhook in the target that reposts every announcement.
    /// Needs Manage Webhooks in the target channel.
    public func followAnnouncementChannel(_ channelID: ChannelID, into target: ChannelID) async throws {
        struct Body: Encodable { var webhook_channel_id: String }
        struct Answer: Decodable {
            var channel_id: String?
            var webhook_id: String?
        }
        _ = try await post(
            "/channels/\(channelID.rawValue)/followers",
            route: "channels/\(channelID.rawValue)/followers",
            body: Body(webhook_channel_id: String(target.rawValue)),
            as: Answer.self
        )
    }
}
