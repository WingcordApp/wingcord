import Foundation

/// A Discord snowflake.
///
/// Stored as `UInt64`, not `String`. Discord sends these as JSON strings
/// because JavaScript cannot hold a 64-bit integer, and a client written in a
/// language that can should not inherit that limitation: an id used as a
/// dictionary key, compared for ordering, or hashed once per row is the single
/// most frequently touched value in the app. A `String` key costs a heap
/// allocation, a retain/release pair and a byte-wise compare where an integer
/// costs a register.
///
/// The generic parameter is a phantom type. It costs nothing at runtime — the
/// layout is exactly `UInt64` — and it makes `ChannelID` and `GuildID`
/// different types to the compiler, so passing one where the other is wanted is
/// a build error rather than a lookup that silently answers nothing.
public struct Snowflake<Tag>: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Parses Discord's string form. Returns nil for anything that is not a
    /// bare decimal integer — never a partial parse.
    public init?(_ string: some StringProtocol) {
        guard let value = UInt64(string) else { return nil }
        rawValue = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { String(rawValue) }

    /// Discord's epoch, 2015-01-01T00:00:00Z, in milliseconds.
    public static var epochMilliseconds: UInt64 { 1_420_070_400_000 }

    /// When this id was minted. The high 42 bits are a millisecond timestamp,
    /// which is why sorting by id sorts by creation time and why the timeline
    /// never needs a separate ordering key.
    public var timestamp: Date {
        Date(
            timeIntervalSince1970:
                Double((rawValue >> 22) &+ Self.epochMilliseconds) / 1000
        )
    }
}

// A snowflake decodes from Discord's string form and encodes back to it, so the
// wire shape is preserved without any call site having to think about it.
extension Snowflake: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = UInt64(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Snowflake is not a decimal integer: \(text)"
            )
        }
        rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(rawValue))
    }
}

public enum GuildTag: Sendable {}
public enum ChannelTag: Sendable {}
public enum MessageTag: Sendable {}
public enum UserTag: Sendable {}
public enum RoleTag: Sendable {}
public enum EmojiTag: Sendable {}
public enum ApplicationTag: Sendable {}
public enum AttachmentTag: Sendable {}

public typealias GuildID = Snowflake<GuildTag>
public typealias ChannelID = Snowflake<ChannelTag>
public typealias MessageID = Snowflake<MessageTag>
public typealias UserID = Snowflake<UserTag>
public typealias RoleID = Snowflake<RoleTag>
public typealias EmojiID = Snowflake<EmojiTag>
public typealias ApplicationID = Snowflake<ApplicationTag>
public typealias AttachmentID = Snowflake<AttachmentTag>
