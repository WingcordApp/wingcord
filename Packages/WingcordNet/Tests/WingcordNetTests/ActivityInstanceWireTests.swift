import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `EMBEDDED_ACTIVITY_UPDATE_V2` and the bootstrap's `activity_instances`.
///
/// The field names are the ones Discord's own gateway handler reads
/// (`{application_id, launch_id, composite_instance_id, location,
/// participants, content_classification}`, web.js, 2026-11-17); the ids are
/// made up.
@Suite("Activity instances on the wire")
struct ActivityInstanceWireTests {

    private func update(_ json: String) throws -> GatewayUpdate? {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        return GatewayUpdate(frame.payload)
    }

    @Test("A server instance decodes with its location, participants and nonce")
    func serverInstance() throws {
        let json = """
        {"op":0,"s":12,"t":"EMBEDDED_ACTIVITY_UPDATE_V2","d":{
          "application_id":"1070087967294631976","launch_id":"1500000000000000123",
          "composite_instance_id":"i-1500000000000000123-gc-1400000000000000001-1400000000000000002",
          "guild_id":"1400000000000000001",
          "location":{"id":"gc-1400000000000000001-1400000000000000002","kind":"gc",
                      "channel_id":"1400000000000000002","guild_id":"1400000000000000001"},
          "participants":[
            {"user_id":"1300000000000000001","session_id":"abc","nonce":"999"},
            {"user_id":"1300000000000000002","session_id":"def",
             "member":{"user":{"id":"1300000000000000002","username":"kim"},"nick":"Kimmy","roles":[]}}
          ],
          "content_classification":null}}
        """
        guard case .activityInstanceChanged(let instance, let members) = try update(json) else {
            Issue.record("not an activity update"); return
        }
        #expect(instance.applicationID == ApplicationID(rawValue: 1_070_087_967_294_631_976))
        #expect(instance.launchID == "1500000000000000123")
        #expect(instance.location.guildID == GuildID(rawValue: 1_400_000_000_000_000_001))
        #expect(instance.channelID == ChannelID(rawValue: 1_400_000_000_000_000_002))
        #expect(instance.frameInstanceID == "i-1500000000000000123-gc-1400000000000000001-1400000000000000002")
        #expect(instance.participants.count == 2)
        let me = UserID(rawValue: 1_300_000_000_000_000_001)
        #expect(instance.includes(me, session: "abc"))
        #expect(!instance.includes(me, session: "elsewhere"))
        #expect(instance.participant(me, session: "abc")?.nonce == "999")
        #expect(members[UserID(rawValue: 1_300_000_000_000_000_002)]?.nickname == "Kimmy")
    }

    @Test("A DM instance with no participants means it ended")
    func endedDirectMessageInstance() throws {
        let json = """
        {"op":0,"s":13,"t":"EMBEDDED_ACTIVITY_UPDATE_V2","d":{
          "application_id":"1211781489931452447","launch_id":"1500000000000000200",
          "location":{"id":"pc-1400000000000000009","kind":"pc","channel_id":"1400000000000000009"},
          "participants":[]}}
        """
        guard case .activityInstanceChanged(let instance, _) = try update(json) else {
            Issue.record("not an activity update"); return
        }
        #expect(instance.location.guildID == nil)
        #expect(instance.isEmpty)
        // No composite on the wire: the frame's id is spelled from the parts.
        #expect(instance.frameInstanceID == "i-1500000000000000200-pc-1400000000000000009")
    }

    @Test("An instance with no application is dropped, not guessed")
    func unreadableInstance() throws {
        let json = """
        {"op":0,"s":14,"t":"EMBEDDED_ACTIVITY_UPDATE_V2","d":{"launch_id":"1","participants":[]}}
        """
        #expect(try update(json) == nil)
    }

    @Test("READY_SUPPLEMENTAL lists each server's running activities, and an unreadable one costs nothing else")
    func supplementalInstances() throws {
        let json = """
        {"guilds":[
          {"id":"1400000000000000001","voice_states":[],"activity_instances":[
            {"application_id":"1070087967294631976","launch_id":"1500000000000000123",
             "location":{"id":"gc-1400000000000000001-1400000000000000002","kind":"gc",
                         "channel_id":"1400000000000000002","guild_id":"1400000000000000001"},
             "participants":[{"user_id":"1300000000000000001","session_id":"abc"}]},
            {"location":"not an object"}
          ]},
          {"id":"1400000000000000005","voice_states":[],"activity_instances":[]}
        ]}
        """
        let payload = try JSONDecoder().decode(ReadySupplementalPayload.self, from: Data(json.utf8))
        let snapshot = ReadySupplementalSnapshot(payload: payload)
        let first = GuildID(rawValue: 1_400_000_000_000_000_001)
        #expect(snapshot.activityInstances[first]?.count == 1)
        #expect(snapshot.activityInstances[first]?.first?.launchID == "1500000000000000123")
        // Listed with none is still listed: that server has nothing running.
        #expect(snapshot.activityInstances[GuildID(rawValue: 1_400_000_000_000_000_005)]?.isEmpty == true)
    }
}
