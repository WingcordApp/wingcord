import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `MESSAGE_ACK` on the wire: another session read a channel, or marked it
/// unread — and only the second may take the cursor back.
struct MessageAckDecodeTests {

    private static func update(_ json: String) throws -> GatewayUpdate? {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        return GatewayUpdate(frame.payload)
    }

    @Test("A Mark Unread in another session says so; an ordinary read does not")
    func manualIsCarried() throws {
        for (body, expected) in [
            (#""manual": true, "mention_count": 2,"#, true),
            (#""manual": false,"#, false),
            ("", false),
        ] {
            let update = try Self.update("""
            {"op": 0, "s": 3, "t": "MESSAGE_ACK", "d": {\(body)
              "version": 41, "message_id": "1426290345343453880", "channel_id": "1302016914117754689"}}
            """)
            guard case .channelAcknowledged(let channel, let message, _, let isManual) = update else {
                Issue.record("not an acknowledgement")
                continue
            }
            #expect(channel == ChannelID(rawValue: 1_302_016_914_117_754_689))
            #expect(message == MessageID(rawValue: 1_426_290_345_343_453_880))
            #expect(isManual == expected)
        }
    }
}
