import Foundation
import WingcordCore

// MARK: - What an activity can share (docs/ACTIVITIES-CALLS-PICKER.md, decision 7)

extension DiscordREST {

    /// An invite that opens the activity, not just the channel: Discord's
    /// `createInvite(channel, {target_type: EMBEDDED_APPLICATION, target_application_id})`,
    /// with the server's own lifetime (Discord sends no `max_age` for these).
    public func createActivityInvite(in channelID: ChannelID, application: ApplicationID) async throws -> String {
        struct Body: Encodable {
            var target_type = 2
            var target_application_id: String
        }
        struct Reply: Decodable { var code: String }
        let reply = try await post(
            "/channels/\(channelID.rawValue)/invites",
            route: "channels/{id}/invites",
            body: Body(target_application_id: String(application.rawValue)),
            as: Reply.self
        )
        return "https://discord.gg/\(reply.code)"
    }

    /// A picture the reader picked for the app (`INITIATE_IMAGE_UPLOAD`):
    /// `POST /applications/{id}/attachment?channel_id=`, one `file` part,
    /// answered with `{attachment: {url}}`, the URL the app is handed.
    public func uploadActivityImage(
        application: ApplicationID,
        channelID: ChannelID?,
        data: Data,
        filename: String,
        contentType: String
    ) async throws -> URL {
        struct Reply: Decodable {
            struct Attachment: Decodable { var url: URL }
            var attachment: Attachment
        }
        let reply = try await requestMultipart(
            method: "POST",
            path: "/applications/\(application.rawValue)/attachment",
            route: "applications/:id/attachment",
            query: channelID.map { [URLQueryItem(name: "channel_id", value: String($0.rawValue))] } ?? [],
            parts: [.init(name: "file", value: .file(data, filename: filename, contentType: contentType))],
            as: Reply.self
        )
        return reply.attachment.url
    }
}
