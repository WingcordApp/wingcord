import Foundation
import WingcordCore

// MARK: - SET_ACTIVITY
//
// Discord's handler (`Ps` in `web.*.js`) in two halves: the Joi schema every
// request is checked against, and what the handler does to an activity that
// passes. The app finishes the job — the pictures need Discord's API — with
// `LocalRPCActivityRequest.resolvingAssets`.

/// One SET_ACTIVITY, checked and shaped as Discord's handler shapes it.
public struct LocalRPCActivityRequest: Sendable {
    /// The game's process, which an IPC client must name — Discord answers
    /// "nonzero pid required" when it does not (a zero is a name).
    public var pid: Int?
    /// The activity, or nil to clear the one this socket set.
    public var activity: RichPresenceActivity?
    /// The pictures still to resolve, by Discord's `fetchAssetIds`: an asset
    /// key, or a link to turn into an `mp:` reference. Nil where none was sent.
    public var largeImage: String?
    public var smallImage: String?

    /// Discord's allowlist for a party id that is also one of its secrets.
    static let secretAllowlist: Set<UInt64> = [1_402_418_171_662_569_542]

    /// Checks `args` against Discord's schema and shapes the activity.
    ///
    /// - Parameters:
    ///   - application: the socket's app — its id, and its name, which an
    ///     activity without one takes.
    ///   - requiresPID: an IPC socket's request, which must name its process.
    ///   - partyPrivacy: the reader's two "who can join" switches
    ///     (`allowActivityPartyPrivacyFriends`, `…VoiceChannel`), which a
    ///     public party's flags carry.
    public init(
        args: RPCValue?,
        application: (id: ApplicationID, name: String),
        requiresPID: Bool,
        partyPrivacy: (friends: Bool, voiceChannel: Bool),
        now: Date = .now
    ) throws(LocalRPC.CommandError) {
        if let failure = LocalRPCSchema.setActivity.failure(of: args) {
            throw LocalRPC.CommandError(.invalidPayload, failure)
        }
        pid = args?["pid"]?.number.map { Int($0) }
        if pid == nil, requiresPID { throw LocalRPC.CommandError(.invalidCommand, "nonzero pid required") }
        guard let fields = args?["activity"], !fields.isNull else {
            activity = nil
            return
        }

        // Secrets are checked as Discord checks them — and then not sent: this
        // client answers no join request, and a JOIN flag would offer one.
        let secrets = ["match", "join", "spectate"].compactMap { fields["secrets"]?[$0]?.string }.filter { !$0.isEmpty }
        let partyID = fields["party"]?["id"]?.string
        let buttons = fields["buttons"]?.array ?? []
        if !secrets.isEmpty {
            if let partyID, secrets.contains(partyID), !Self.secretAllowlist.contains(application.id.rawValue) {
                throw LocalRPC.CommandError(.invalidActivitySecret, "secrets cannot match the party id")
            }
            if Set(secrets).count < secrets.count {
                throw LocalRPC.CommandError(.invalidActivitySecret, "secrets must be unique")
            }
            if fields["buttons"] != nil {
                throw LocalRPC.CommandError(.invalidActivitySecret, "secrets cannot currently be sent with buttons")
            }
        }

        let assets = fields["assets"]
        largeImage = assets?["large_image"]?.string
        smallImage = assets?["small_image"]?.string
        let privacy = Int(fields["party"]?["privacy"]?.number ?? 0)

        var activity = RichPresenceActivity(
            type: Int(fields["type"]?.number ?? 0),
            // `r.name||(r.name=…)`: an empty name is no name.
            name: fields["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? application.name,
            details: fields["details"]?.string,
            state: fields["state"]?.string,
            assets: assets.map {
                RichPresenceActivity.Assets(
                    largeText: $0["large_text"]?.string,
                    largeURL: $0["large_url"]?.string.flatMap(URL.init(string:)),
                    smallText: $0["small_text"]?.string,
                    smallURL: $0["small_url"]?.string.flatMap(URL.init(string:))
                )
            },
            timestamps: fields["timestamps"].map {
                RichPresenceActivity.Timestamps(
                    start: $0["start"]?.number.map { Self.milliseconds($0, now: now) },
                    end: $0["end"]?.number.map { Self.milliseconds($0, now: now) }
                )
            },
            party: fields["party"].map {
                RichPresenceActivity.Party(
                    id: partyID,
                    size: $0["size"]?.array?.compactMap { $0.number.map { Int($0) } }
                )
            },
            buttons: buttons.compactMap { $0["label"]?.string },
            applicationID: application.id,
            flags: Self.flags(
                instance: fields["instance"]?.bool == true,
                isPublic: privacy == 1,
                partyPrivacy: partyPrivacy
            )
        )
        activity.buttonURLs = buttons.compactMap { $0["url"]?.string.flatMap(URL.init(string:)) }
        activity.detailsURL = fields["details_url"]?.string.flatMap(URL.init(string:))
        activity.stateURL = fields["state_url"]?.string.flatMap(URL.init(string:))
        activity.statusDisplayType = fields["status_display_type"]?.number.map { Int($0) }
        self.activity = activity
    }

    /// The activity with its pictures resolved — Discord's `fetchAssetIds`
    /// answer, by position: a picture that resolved takes its id or its `mp:`
    /// reference, and one that did not, or was never sent, is left out.
    public func resolvingAssets(large: String?, small: String?) -> RichPresenceActivity? {
        guard var activity else { return nil }
        if var assets = activity.assets {
            assets.largeImage = large
            assets.smallImage = small
            activity.assets = assets
        }
        return activity
    }

    /// Discord's flags for a local activity (`182892`'s `E`): INSTANCE for an
    /// instance; for a public party, who may join it — friends, people in the
    /// reader's voice channel — as the reader's privacy switches allow.
    static func flags(instance: Bool, isPublic: Bool, partyPrivacy: (friends: Bool, voiceChannel: Bool)) -> Int {
        var flags = instance ? 1 : 0
        if isPublic {
            if partyPrivacy.friends { flags |= 64 }
            if partyPrivacy.voiceChannel { flags |= 128 }
        }
        return flags
    }

    /// Seconds become milliseconds the way Discord tells them apart: a value
    /// whose written length falls more than two digits short of `Date.now()`'s
    /// is taken for seconds and multiplied, then floored.
    static func milliseconds(_ value: Double, now: Date) -> Int {
        let nowLength = String(Int64(now.timeIntervalSince1970 * 1000)).count
        guard nowLength - javaScriptLength(of: value) > 2 else { return Int(value) }
        return Int((value * 1000).rounded(.down))
    }

    /// How long JavaScript writes a number: a whole one as its digits, any
    /// other as its shortest decimal — which is Swift's own `description`.
    static func javaScriptLength(of value: Double) -> Int {
        if value.rounded() == value, abs(value) < 1e21 { return String(Int64(value)).count }
        return value.description.count
    }
}

// MARK: - The schema

/// Discord's Joi schemas for the RPC commands this server answers, checked as
/// Joi 13 checks them with `{convert: false}`: the first failure only, the
/// schema's own key order, and Joi's own sentence for it — which Discord sends
/// back word for word. The sentences were generated by running Discord's
/// bundled Joi (`88137`) on the same schema; `LocalRPCActivityTests` holds them.
indirect enum LocalRPCSchema: Sendable {
    /// `MS(e).keys(…)` — an object whose unknown keys are allowed.
    case object([(key: String, schema: LocalRPCSchema)], allowsNull: Bool)
    case string(min: Int, max: Int, isURI: Bool)
    case number(min: Double?, valid: [Double]?)
    case boolean
    case array(items: LocalRPCSchema, min: Int?, max: Int?, length: Int?)
    case required(LocalRPCSchema)

    /// SET_ACTIVITY's `validation`, key for key.
    static let setActivity: LocalRPCSchema = .required(.object([
        ("pid", .number(min: 0, valid: nil)),
        ("activity", .object([
            ("name", .string(min: 1, max: 128, isURI: false)),
            ("state", .string(min: 2, max: 128, isURI: false)),
            ("state_url", .string(min: 1, max: 256, isURI: true)),
            ("details", .string(min: 2, max: 128, isURI: false)),
            ("details_url", .string(min: 1, max: 256, isURI: true)),
            ("timestamps", .object([
                ("start", .number(min: 1, valid: nil)),
                ("end", .number(min: 1, valid: nil)),
            ], allowsNull: false)),
            ("assets", .object([
                ("large_image", .string(min: 1, max: 300, isURI: false)),
                ("large_text", .string(min: 2, max: 128, isURI: false)),
                ("large_url", .string(min: 1, max: 256, isURI: true)),
                ("small_image", .string(min: 1, max: 300, isURI: false)),
                ("small_text", .string(min: 2, max: 128, isURI: false)),
                ("small_url", .string(min: 1, max: 256, isURI: true)),
                ("invite_cover_image", .string(min: 1, max: 300, isURI: false)),
            ], allowsNull: false)),
            ("party", .object([
                ("id", .string(min: 2, max: 128, isURI: false)),
                ("size", .array(items: .number(min: 0, valid: nil), min: nil, max: nil, length: 2)),
                ("privacy", .number(min: nil, valid: [0, 1])),
            ], allowsNull: false)),
            ("secrets", .object([
                ("match", .string(min: 2, max: 128, isURI: false)),
                ("join", .string(min: 2, max: 128, isURI: false)),
                ("spectate", .string(min: 2, max: 128, isURI: false)),
            ], allowsNull: false)),
            ("buttons", .array(
                items: .object([
                    ("label", .required(.string(min: 1, max: 32, isURI: false))),
                    ("url", .required(.string(min: 1, max: 512, isURI: true))),
                ], allowsNull: false),
                min: 1, max: 2, length: nil
            )),
            ("instance", .boolean),
            ("supported_platforms", .array(items: .string(min: 1, max: 32, isURI: false), min: 1, max: 10, length: nil)),
            ("type", .number(min: nil, valid: [0, 2, 3, 5])),
            ("status_display_type", .number(min: nil, valid: [0, 1, 2])),
        ], allowsNull: true)),
    ], allowsNull: false))

    /// Joi's sentence for the first thing wrong with `value`, or nil. A nil
    /// value is an absent one — JavaScript's `undefined` — and the root is
    /// called "value", as Joi calls it.
    func failure(of value: RPCValue?, label: String = "value") -> String? {
        if case .required(let inner) = self {
            guard value != nil else { return "\"\(label)\" is required" }
            return inner.failure(of: value, label: label)
        }
        guard let value else { return nil }
        switch self {
        case .required:
            return nil
        case .object(let keys, let allowsNull):
            if allowsNull, value.isNull { return nil }
            guard case .object(let fields) = value else { return "\"\(label)\" must be an object" }
            for (key, schema) in keys {
                if let inner = schema.failure(of: fields[key], label: key) {
                    return "child \"\(key)\" fails because [\(inner)]"
                }
            }
            return nil
        case .string(let min, let max, let isURI):
            guard case .string(let text) = value else { return "\"\(label)\" must be a string" }
            if text.isEmpty { return "\"\(label)\" is not allowed to be empty" }
            if isURI, text.wholeMatch(of: Self.uri) == nil { return "\"\(label)\" must be a valid uri" }
            // JavaScript's length: UTF-16 units.
            let length = text.utf16.count
            if length < min { return "\"\(label)\" length must be at least \(min) characters long" }
            if length > max { return "\"\(label)\" length must be less than or equal to \(max) characters long" }
            return nil
        case .number(let min, let valid):
            guard case .number(let number) = value else { return "\"\(label)\" must be a number" }
            if let valid, !valid.contains(number) {
                return "\"\(label)\" must be one of [\(valid.map(Self.written).joined(separator: ", "))]"
            }
            if let min, number < min { return "\"\(label)\" must be larger than or equal to \(Self.written(min))" }
            return nil
        case .boolean:
            guard case .bool = value else { return "\"\(label)\" must be a boolean" }
            return nil
        case .array(let items, let min, let max, let length):
            guard case .array(let elements) = value else { return "\"\(label)\" must be an array" }
            for (index, element) in elements.enumerated() {
                if let inner = items.failure(of: element, label: String(index)) {
                    return "\"\(label)\" at position \(index) fails because [\(inner)]"
                }
            }
            if let length, elements.count != length { return "\"\(label)\" must contain \(length) items" }
            if let min, elements.count < min { return "\"\(label)\" must contain at least \(min) items" }
            if let max, elements.count > max {
                return "\"\(label)\" must contain less than or equal to \(max) items"
            }
            return nil
        }
    }

    /// A number as JavaScript writes it into the sentence.
    private static func written(_ number: Double) -> String {
        number.rounded() == number ? String(Int64(number)) : number.description
    }

    /// Joi's `uri()` — RFC 3986, built from the grammar's parts exactly as
    /// Joi 13's `rfc3986` module builds it.
    nonisolated(unsafe) static let uri: Regex<AnyRegexOutput> = {
        let digit = "[0-9]"
        let alpha = "a-zA-Z"
        let hexDigit = "[0-9A-Fa-f]"
        let unreserved = alpha + "0-9-\\._~"
        let subDelims = "!\\$&'\\(\\)\\*\\+,;="
        let pctEncoded = "%0-9A-Fa-f"
        let pchar = unreserved + pctEncoded + subDelims + ":@"
        let pcharOnly = "[" + pchar + "]"
        let decOctet = "(?:0?0?" + digit + "|0?[1-9]" + digit + "|1" + digit + digit + "|2[0-4]" + digit + "|25[0-5])"
        let ipv4 = "(?:" + decOctet + "\\.){3}" + decOctet
        let h16 = hexDigit + "{1,4}"
        let ls32 = "(?:" + h16 + ":" + h16 + "|" + ipv4 + ")"
        let ipv6 = "(?:(?:" + h16 + ":){6}" + ls32
            + "|::(?:" + h16 + ":){5}" + ls32
            + "|(?:" + h16 + ")?::(?:" + h16 + ":){4}" + ls32
            + "|(?:(?:" + h16 + ":){0,1}" + h16 + ")?::(?:" + h16 + ":){3}" + ls32
            + "|(?:(?:" + h16 + ":){0,2}" + h16 + ")?::(?:" + h16 + ":){2}" + ls32
            + "|(?:(?:" + h16 + ":){0,3}" + h16 + ")?::" + h16 + ":" + ls32
            + "|(?:(?:" + h16 + ":){0,4}" + h16 + ")?::" + ls32
            + "|(?:(?:" + h16 + ":){0,5}" + h16 + ")?::" + h16
            + "|(?:(?:" + h16 + ":){0,6}" + h16 + ")?::)"
        let ipvFuture = "v" + hexDigit + "+\\.[" + unreserved + subDelims + ":]+"
        let scheme = "[" + alpha + "][" + alpha + "0-9+-\\.]*"
        let host = "(?:\\[(?:" + ipv6 + "|" + ipvFuture + ")\\]|" + ipv4 + "|[" + unreserved + pctEncoded + subDelims + "]{0,255})"
        let authority = "(?:[" + unreserved + pctEncoded + subDelims + ":]*@)?" + host + "(?::" + digit + "*)?"
        let segment = pcharOnly + "*"
        let segmentNonZero = pcharOnly + "+"
        let pathAbEmpty = "(?:\\/" + segment + ")*"
        let pathAbsolute = "\\/(?:" + segmentNonZero + pathAbEmpty + ")?"
        let pathRootless = segmentNonZero + pathAbEmpty
        let hierPart = "(?:(?:\\/\\/" + authority + pathAbEmpty + ")|" + pathAbsolute + "|" + pathRootless + ")"
        let query = "[" + pchar + "\\/\\?]*(?=#|$)"
        let fragment = "[" + pchar + "\\/\\?]*"
        // A constant pattern; `LocalRPCActivityTests` compiles it.
        return try! Regex("(?:" + scheme + ":" + hierPart + ")(?:\\?" + query + ")?(?:#" + fragment + ")?")
    }()
}
