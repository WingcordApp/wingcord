import Foundation
import WingcordCore

/// The line under somebody's name — Discord's `ActivityStatus` — for the three
/// surfaces that draw it: the member list, the direct-message list and the now
/// bar. See `ActivityStatusLine` for the rules themselves.
extension AppModel {

    /// The line under one person's name, or nil for none.
    ///
    /// **Nothing for somebody offline or invisible**, whatever else is true —
    /// Discord's own guard (module `397244`), and what keeps a roster's offline
    /// half a column of names.
    static func activityLine(
        presence: Presence?,
        isBot: Bool,
        voice: ActivityStatusLine.VoicePlace?,
        isStreaming: Bool
    ) -> ActivityStatusLine? {
        guard let presence, presence.status != .offline, presence.status != .invisible else {
            return nil
        }
        let line = ActivityStatusLine.resolve(
            activities: presence.activities?.list ?? [],
            isStreaming: isStreaming,
            voice: voice,
            isBot: isBot
        )
        return line.isEmpty ? nil : line
    }

    /// Where somebody is talking — in any server, as far as the reader can see
    /// the room — and whether they are sharing a screen there.
    ///
    /// **A private call always counts**; a server room counts only when the
    /// reader may see it, which is Discord's own gate on the channel it names
    /// (module `714114`). A screen share in a room the reader cannot see is not
    /// announced either.
    func voicePlace(of userID: UserID) -> (place: ActivityStatusLine.VoicePlace?, isStreaming: Bool) {
        guard let state = voiceStates[userID], let channelID = state.channelID else {
            return (nil, false)
        }
        guard state.guildID != nil else { return (.call, state.isStreaming) }
        guard let kind = channelIndex[channelID]?.kind, permissionGate.canView(channelID) else {
            return (nil, false)
        }
        return (kind == .stage ? .stage : .voiceChannel, state.isStreaming)
    }

    /// The now bar's line — Discord's account panel (module `44137`), which is
    /// the member list's line about the reader.
    ///
    /// **The custom status survives being invisible.** Discord's panel shows it
    /// on its own when the reader is hidden, because hiding from everybody else
    /// is not hiding from yourself; the activities and the call are what go.
    ///
    /// The status is the account's own setting rather than the mirrored
    /// presence — what the reader last set, including the moments before the
    /// gateway has said so.
    func nowBarActivityLine(user: User?) -> ActivityStatusLine? {
        guard let userID = currentUserID else { return nil }
        var activities = (selfCustomStatus?.current()).map {
            [Activity(kind: .custom, name: "Custom Status", state: $0.text, emoji: $0.emoji)]
        } ?? []
        var voice: (place: ActivityStatusLine.VoicePlace?, isStreaming: Bool) = (nil, false)
        if selfStatus != .invisible, selfStatus != .offline {
            activities += (presences[userID]?.activities?.list ?? []).filter { $0.kind != .custom }
            voice = voicePlace(of: userID)
        }
        let line = ActivityStatusLine.resolve(
            activities: ActivityOrder.presented(activities),
            isStreaming: voice.isStreaming,
            voice: voice.place,
            isBot: user?.isBot ?? false
        )
        return line.isEmpty ? nil : line
    }
}
