import Foundation
import WingcordCore

// MARK: - Clips of one moment, from everybody in the call
//
// docs/CLIPS-PRESENCE.md, Phase 7.3. Discord's distributed clips
// (`2026-05-distributed-clips`, build 643186): a clip somebody asks for while
// playing is announced to the channel they are in, and the server hands back
// the moment's id; everybody else in the call running the same game hears
// `CLIPS_REMOTE_TRIGGER` and keeps the same moment from where they were.
// Shared, each carries the id as `clip_remote_id`, and the player switches
// between them.

extension DiscordREST {

    /// `POST /channels/{id}/clips-remote-trigger {application_id}` — the
    /// moment's id, which the reader's own clip then carries.
    public func sendClipsRemoteTrigger(in channelID: ChannelID, applicationID: UInt64) async throws -> String? {
        struct Body: Encodable { var application_id: String }
        struct Reply: Decodable { var remote_clip_id: String? }
        return try await post(
            "/channels/\(channelID.rawValue)/clips-remote-trigger",
            route: "channels/{id}/clips-remote-trigger",
            body: Body(application_id: String(applicationID)),
            as: Reply.self
        ).remote_clip_id
    }
}

/// `CLIPS_REMOTE_TRIGGER`: somebody in the reader's call clipped a moment.
public struct ClipsRemoteTrigger: Hashable, Sendable {
    public var userID: UserID
    public var applicationID: UInt64
    public var partyID: String?
    public var remoteClipID: String
}

struct ClipsRemoteTriggerDTO: Decodable, Sendable {
    var user_id: UserID
    var application_id: String
    var party_id: String?
    var remote_clip_id: String

    var domain: ClipsRemoteTrigger? {
        guard let applicationID = UInt64(application_id) else { return nil }
        return ClipsRemoteTrigger(
            userID: user_id, applicationID: applicationID, partyID: party_id, remoteClipID: remote_clip_id
        )
    }
}
