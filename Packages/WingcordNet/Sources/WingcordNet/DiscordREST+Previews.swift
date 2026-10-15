import Foundation
import WingcordCore

extension DiscordREST {
    /// The newest message in each of `channelIDs` — Discord's mobile app's
    /// message previews (`MESSAGE_PREVIEWS`, `POST /channels/preload-messages`).
    ///
    /// **A route Discord's desktop and web clients define and never call**
    /// (bundle, 2026-10-13: the route constant and its `MESSAGE_PREVIEWS_LOADED`
    /// handler are there, no caller is); its phones call it to fill their
    /// conversation list's preview lines, which is the one thing this is for.
    /// At most a hundred channels a request, Discord's limit. One message per
    /// channel comes back, the channel's latest, in no promised order; read
    /// leniently, so one unfamiliar message cannot drop the rest.
    public func preloadMessages(channelIDs: [ChannelID]) async throws -> MessagePage {
        struct Body: Encodable {
            var channel_ids: [String]
        }
        let ids = channelIDs.prefix(Self.previewChannelLimit).map(\.description)
        guard !ids.isEmpty else { return MessagePage(messages: [], authors: [:]) }
        let list = try await post(
            "/channels/preload-messages",
            route: "channels/preload-messages",
            body: Body(channel_ids: Array(ids)),
            as: LossyList<MessageDTO>.self
        )
        return Self.page(from: list.elements, reversed: false, wireCount: list.wireCount)
    }

    /// The most channels one preview request may name.
    public static let previewChannelLimit = 100
}
