import Foundation
import WingcordCore

/// `call` on a `CALL` message: `{participants: [snowflake], ended_timestamp}`.
///
/// **Never throws**, like `guild_space_data`: a shape this client does not
/// know leaves the line saying "started a call." as it always did, rather than
/// failing the whole message — and with it the page it arrived on.
struct MessageCallDTO: Decodable {
    var participants: [LossyID] = []
    var ended_timestamp: String?

    private enum CodingKeys: String, CodingKey {
        case participants, ended_timestamp
    }

    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        participants = (try? container?.decodeIfPresent([LossyID].self, forKey: .participants)) ?? []
        ended_timestamp = try? container?.decodeIfPresent(String.self, forKey: .ended_timestamp)
    }

    var domain: MessageCall {
        MessageCall(
            participantIDs: participants.map { UserID(rawValue: $0.value) },
            endedAt: ended_timestamp.flatMap {
                ISO8601DateFormatter.withFraction.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0)
            }
        )
    }
}
