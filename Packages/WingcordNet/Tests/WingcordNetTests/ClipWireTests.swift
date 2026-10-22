import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A Discord clip on the wire (docs/CLIPS-PRESENCE.md, Phase 4.1): the
/// attachment's clip fields read back, and the two places a share writes them;
/// a timeline comment's `media_mention`.
struct ClipWireTests {

    private static let clipMessage = #"""
    {"id":"10","channel_id":"2","author":{"id":"3","username":"alex"},"content":"","type":0,
     "attachments":[{"id":"4","filename":"Minecraft.mp4","url":"https://cdn/x.mp4","proxy_url":"https://media/x.mp4",
       "content_type":"video/mp4","size":123,"duration_secs":30.5,"flags":256,
       "is_clip":true,"title":"clutch","application":{"id":"356875570920743315","name":"Minecraft"},
       "clip_created_at":"2026-10-21T04:49:30.123000+00:00",
       "clip_participants":[{"id":"3","username":"alex"},{"id":"5","username":"kim","global_name":"Kim"},{"broken":true}],
       "clip_events_timeline":[{"timestamp_ms":0,"speaking":{"user_id":"5","speaking_flags":1}},
                               {"timestamp_ms":900,"game":{"type":2,"event_name":"Triple Kill"}},
                               {"timestamp_ms":1200,"hologram":{"kind":7}}]}],
     "embeds":[]}
    """#

    @Test("A clip attachment reads as Discord's player reads it, and a bad part costs only itself")
    func decodesClip() throws {
        let message = try DiscordREST.decoder.decode(MessageDTO.self, from: Data(Self.clipMessage.utf8)).domain
        let clip = try #require(message.attachments.first?.clip)
        #expect(clip.title == "clutch")
        #expect(clip.applicationID == 356_875_570_920_743_315)
        #expect(clip.applicationName == "Minecraft")
        #expect(clip.createdAt != nil)
        #expect(clip.participants.map(\.id.rawValue) == [3, 5])
        #expect(clip.timeline.count == 2, "a kind this build does not know is left out")
        #expect(clip.hasTimelineComments)
        #expect(clip.hasSpeaking)
        #expect(clip.speakers(at: 500) == [5])

        let plain = #"""
        {"id":"1","channel_id":"2","author":{"id":"3","username":"alex"},"content":"","type":0,
         "attachments":[{"id":"4","filename":"a.mp4","url":"u","proxy_url":"p","content_type":"video/mp4"}]}
        """#
        let video = try DiscordREST.decoder.decode(MessageDTO.self, from: Data(plain.utf8)).domain
        #expect(video.attachments.first?.clip == nil, "an ordinary video is not a clip")

        // Discord's own client knows a clip by `IS_CLIP` alone (module 650019).
        let flagged = #"""
        {"id":"1","channel_id":"2","author":{"id":"3","username":"alex"},"content":"","type":0,
         "attachments":[{"id":"4","filename":"a.mp4","url":"u","proxy_url":"p","content_type":"video/mp4","flags":1}]}
        """#
        let clip2 = try DiscordREST.decoder.decode(MessageDTO.self, from: Data(flagged.utf8)).domain
        #expect(clip2.attachments.first?.clip != nil, "the IS_CLIP flag makes a clip")
        #expect(clip2.attachments.first?.clip?.hasTimelineComments == false)
    }

    @Test("A timeline comment's moment reads, and a reply writes it")
    func mediaMention() throws {
        let json = #"""
        {"id":"11","channel_id":"2","author":{"id":"5","username":"kim"},"content":"lmao","type":19,
         "message_reference":{"message_id":"10","channel_id":"2"},
         "media_mention":{"attachment_id":"4","timestamp":12345,"message_id":"10"}}
        """#
        let message = try DiscordREST.decoder.decode(MessageDTO.self, from: Data(json.utf8)).domain
        #expect(message.mediaMention == MediaMention(attachmentID: AttachmentID(rawValue: 4), timestampMS: 12_345))

        let data = try JSONEncoder().encode(MediaMentionDTO(MediaMention(attachmentID: AttachmentID(rawValue: 4), timestampMS: 900)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["attachment_id"] as? String == "4")
        #expect(object["timestamp"] as? Int == 900)
        #expect(object["message_id"] == nil, "a send never names the reply's own id")
    }

    @Test("A shared clip writes its fields on the upload slot and on the message's attachment")
    func encodesClip() async throws {
        let upload = ClipUpload(
            title: "clutch", applicationID: 356_875_570_920_743_315,
            createdAt: Date(timeIntervalSince1970: 1_792_644_570.123),
            participantIDs: [3, 5],
            timeline: [ClipTimelineEvent(timestampMS: 0, event: .speaking(userID: 5, flags: 1))],
            durationSeconds: 30.5
        )
        let (rest, token) = await RequestRecorder.client(body: #"{"attachments":[{"id":0,"upload_url":"https://up/x","upload_filename":"abc"}]}"#)
        _ = try await rest.createUploadSlots(
            in: ChannelID(rawValue: 2), for: [UploadRequest(filename: "clutch.mp4", size: 123, clip: upload)]
        )
        let request = try #require(RequestRecorder.requests(for: token).last)
        let file = try #require((request.json?["files"] as? [[String: Any]])?.first)
        #expect(file["is_clip"] as? Bool == true)
        #expect(file["title"] as? String == "clutch")
        #expect(file["application_id"] as? String == "356875570920743315")
        #expect(file["clip_participant_ids"] as? [String] == ["3", "5"])
        #expect((file["clip_created_at"] as? String)?.hasSuffix("Z") == true)
        #expect((file["clip_events_timeline"] as? [[String: Any]])?.count == 1)

        let body = try JSONEncoder().encode(AttachmentBody(UploadedAttachment(
            id: "0", filename: "clutch.mp4", uploadedFilename: "abc", clip: upload
        )))
        let entry = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(entry["uploaded_filename"] as? String == "abc")
        #expect(entry["is_clip"] as? Bool == true)
        #expect(entry["duration_secs"] as? Double == 30.5)

        // An ordinary file says it is not a clip, and nothing else.
        let ordinary = try JSONEncoder().encode(AttachmentBody(UploadedAttachment(id: "0", filename: "a.png", uploadedFilename: "z")))
        let plain = try #require(try JSONSerialization.jsonObject(with: ordinary) as? [String: Any])
        #expect(plain["is_clip"] == nil && plain["title"] == nil)
    }

    // MARK: One moment from everybody (Phase 7.3)

    @Test("Somebody in the call clipped: the dispatch reads as the app's event")
    func remoteTrigger() throws {
        let json = #"{"op":0,"s":3,"t":"CLIPS_REMOTE_TRIGGER","d":{"user_id":"5","application_id":"356875570920743315","party_id":null,"remote_clip_id":"rc-1"}}"#
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        guard case .clipsRemoteTrigger(let trigger)? = GatewayUpdate(frame.payload) else {
            Issue.record("the trigger should have been read")
            return
        }
        #expect(trigger.userID == UserID(rawValue: 5))
        #expect(trigger.applicationID == 356_875_570_920_743_315)
        #expect(trigger.remoteClipID == "rc-1")
        #expect(trigger.partyID == nil)
    }

    @Test("A clip of a shared moment says so when shared, and the trigger asks for the moment's id")
    func remoteFields() async throws {
        let upload = ClipUpload(
            title: "clutch", applicationID: 1, createdAt: Date(timeIntervalSince1970: 1_792_644_570.5),
            participantIDs: [3], timeline: [], durationSeconds: 10,
            remoteID: "rc-1", syncTimestamp: Date(timeIntervalSince1970: 1_792_644_570.5)
        )
        let body = try JSONEncoder().encode(AttachmentBody(UploadedAttachment(
            id: "0", filename: "clutch.mp4", uploadedFilename: "abc", clip: upload
        )))
        let entry = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(entry["clip_remote_id"] as? String == "rc-1")
        #expect((entry["clip_sync_timestamp"] as? String)?.hasSuffix("Z") == true)

        let (rest, token) = await RequestRecorder.client(body: #"{"remote_clip_id":"rc-9"}"#)
        let id = try await rest.sendClipsRemoteTrigger(in: ChannelID(rawValue: 42), applicationID: 7)
        #expect(id == "rc-9")
        let request = try #require(RequestRecorder.requests(for: token).last)
        #expect(request.method == "POST")
        #expect(request.path.hasSuffix("/channels/42/clips-remote-trigger"))
        #expect(request.json?["application_id"] as? String == "7")
    }
}
