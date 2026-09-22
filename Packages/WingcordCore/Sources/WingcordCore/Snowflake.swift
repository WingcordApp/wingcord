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

    /// The smallest id that could have been minted at `date`.
    ///
    /// **A stand-in cursor, not a real id.** Discord's own inbox uses one for a
    /// channel the reader has never acknowledged: the day they joined the
    /// server becomes the cursor, so nothing posted before they arrived can
    /// count as unread. Without it every message a channel has ever carried is
    /// unread, and a summary opens on a conversation from years before the
    /// reader was there.
    ///
    /// Clamped at the epoch: a date before 2015 has no snowflake, and wrapping
    /// the subtraction would produce an id larger than every real one — a
    /// cursor that swallows the whole channel instead of none of it.
    public init(before date: Date) {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        rawValue = milliseconds > Self.epochMilliseconds
            ? (milliseconds &- Self.epochMilliseconds) << 22
            : 0
    }
}

// A snowflake encodes back to Discord's string form, so the wire shape is
// preserved without any call site having to think about it.
extension Snowflake: Codable {
    /// Decodes a snowflake from **either** a string or a number.
    ///
    /// **Discord sends both, in the same payload.** Snowflakes are documented as
    /// strings — JavaScript cannot hold a 64-bit integer, which is the whole
    /// reason for the convention — but the rule is not enforced everywhere, and
    /// a READY carrying four hundred read-state entries has been observed with
    /// `last_message_id` as a bare number on some of them.
    ///
    /// A decoder that accepts only the documented form fails the WHOLE bootstrap
    /// on one such field: the payload is one JSON document, so a single type
    /// mismatch seven megabytes in throws away everything. That is not a
    /// hypothetical — it is the defect this initialiser was written to fix, and
    /// it presented as a client that connected and then sat on "Connecting…"
    /// forever.
    ///
    /// The number is decoded as `UInt64` and never as `Double`: a snowflake is
    /// 19 digits and a `Double` has 53 bits of mantissa, so going through one
    /// silently rounds the low digits away and produces an id that belongs to
    /// nothing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let text = try? container.decode(String.self) {
            guard let value = UInt64(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "snowflake is not a decimal integer: \(text)"
                )
            }
            rawValue = value
            return
        }

        if let value = try? container.decode(UInt64.self) {
            rawValue = value
            return
        }

        throw DecodingError.typeMismatch(
            Snowflake<Tag>.self,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "snowflake was neither a string nor an unsigned integer"
            )
        )
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
/// The RTC server a Go Live stream is allocated on.
///
/// Snowflake-shaped and snowflake-encoded — a decimal integer arriving as a
/// JSON string — but **it is not a snowflake**: nothing mints it from a clock,
/// so `timestamp` on one means nothing. It is tagged separately so it cannot be
/// passed where a channel or a guild is wanted, and because the id a stream's
/// MLS group is keyed on is derived from it rather than equal to it — see
/// its `rtc_channel_id`, which the same frame carries.
public enum RTCServerTag: Sendable {}
/// An OAuth2 grant — `GET /oauth2/tokens`'s own `id`, not the application's.
/// A genuine snowflake: `DELETE /oauth2/tokens/{id}` takes it, and its
/// `timestamp` is the only place "authorized on" comes from — the response
/// carries no date field of its own.
public enum OAuthGrantTag: Sendable {}
/// One of a forum's own tags — the chips a post is filed under.
///
/// Tagged apart from every other id because a tag is only meaningful against the
/// forum that defines it: the same integer names nothing in another channel, and
/// resolving one is always a lookup into *that* forum's `availableTags`.
public enum ForumTagTag: Sendable {}
public enum StageInstanceTag: Sendable {}
public enum ScheduledEventTag: Sendable {}
public enum JoinRequestTag: Sendable {}

public typealias GuildID = Snowflake<GuildTag>
public typealias ChannelID = Snowflake<ChannelTag>
public typealias MessageID = Snowflake<MessageTag>
public typealias UserID = Snowflake<UserTag>
public typealias RoleID = Snowflake<RoleTag>
public typealias EmojiID = Snowflake<EmojiTag>
public typealias ApplicationID = Snowflake<ApplicationTag>
public typealias AttachmentID = Snowflake<AttachmentTag>
public typealias RTCServerID = Snowflake<RTCServerTag>
public typealias OAuthGrantID = Snowflake<OAuthGrantTag>
public typealias ForumTagID = Snowflake<ForumTagTag>
/// A live stage's own id, and the scheduled event a stage may belong to.
///
/// **They exist because two fields were typed `UInt64` and Discord sends every
/// snowflake as a string.** Nothing reads either value — a stage is keyed on its
/// channel — which is exactly why it went unnoticed: the fields were decoded and
/// discarded, so the only thing they could ever do was throw, and they did. One
/// server with a live stage took the whole of READY down with it.
public typealias StageInstanceID = Snowflake<StageInstanceTag>
public typealias ScheduledEventID = Snowflake<ScheduledEventTag>
public typealias JoinRequestID = Snowflake<JoinRequestTag>
