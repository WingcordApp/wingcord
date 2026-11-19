import Foundation
import WingcordCore

extension DiscordREST {
    /// `GET /guilds/{id}/new-member-actions`: which Get Started steps the
    /// reader has done, as `{channel_actions: {<channel>: {completed}}}`
    /// (Discord's `225142.aW`).
    public func guideProgress(of guildID: GuildID) async throws -> Set<ChannelID> {
        struct Answer: Decodable {
            struct Step: Decodable { var completed: Bool? }
            var channel_actions: [String: Step]?
        }
        let answer = try await get(
            "/guilds/\(guildID.rawValue)/new-member-actions",
            route: "guilds/{id}/new-member-actions",
            as: Answer.self
        )
        var done = Set<ChannelID>()
        for (key, step) in answer.channel_actions ?? [:] where step.completed == true {
            if let raw = UInt64(key) { done.insert(ChannelID(rawValue: raw)) }
        }
        return done
    }

    /// `POST /guilds/{id}/new-member-action/{channel}`: one step done, as
    /// Discord's client tells it (`225142.eC`).
    public func completeGuideStep(_ channelID: ChannelID, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/new-member-action/\(channelID.rawValue)",
            route: "guilds/{id}/new-member-action/{channel}",
            body: Optional<Never>.none
        )
    }
}
