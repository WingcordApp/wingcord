import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// Delete User's Message on the wire — Discord's `995786.E5` body.
@Suite("AutoMod alert actions on the wire")
struct AutoModAlertActionWireTests {
    @Test("The alert's own ids, as strings, and the action's number")
    func body() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = AutoModAlertActionBody(
            action: .deleteUserMessage,
            alertID: MessageID(rawValue: 1_234_567_890_123_456_789),
            channelID: ChannelID(rawValue: 42)
        )
        let json = try #require(String(data: encoder.encode(body), encoding: .utf8))
        #expect(json == #"{"alert_action_type":3,"channel_id":"42","message_id":"1234567890104688129"}"#)
    }
}
