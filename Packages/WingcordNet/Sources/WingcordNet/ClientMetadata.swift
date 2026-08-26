import Foundation

/// The identifying headers Discord's own desktop client sends.
///
/// Built once per session and shared by REST and the gateway, because they must
/// agree: a client whose `X-Super-Properties` says one thing and whose IDENTIFY
/// says another is a client that stands out, and standing out is the one thing a
/// third-party client must not do.
///
/// Nothing here is a secret and nothing is invented — these are the same public
/// environment values Discord's web client puts in the clear on every request.
public struct ClientMetadata: Sendable {
    public struct Baseline: Sendable {
        public var apiVersion: Int
        public var webBuildNumber: Int
        public var nativeBuildNumber: Int
        public var desktopVersion: String
        public var electronVersion: String
        public var chromiumVersion: String

        /// Observed from a live client. **These go stale**: Discord ships builds
        /// continuously and a build number far behind the current one is a
        /// signal. Re-read them from a running client rather than guessing, and
        /// change them here — one place, both transports.
        public static let current = Baseline(
            apiVersion: 9,
            webBuildNumber: 587_597,
            nativeBuildNumber: 87_263,
            desktopVersion: "0.0.403",
            electronVersion: "42.7.1",
            chromiumVersion: "148.0.7778.280"
        )
    }

    public let baseline: Baseline
    public let locale: String
    public let timeZone: String
    public let userAgent: String
    /// Base64 of the properties object, which is what the header carries.
    public let superProperties: String
    /// The same properties as a value, for IDENTIFY.
    public let identifyProperties: [String: JSONScalar]

    public init(baseline: Baseline = .current) {
        self.baseline = baseline
        locale = Locale.preferredLanguages.first ?? "en-US"
        timeZone = TimeZone.current.identifier

        let webKit = "537.36"
        userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/\(webKit) "
            + "(KHTML, like Gecko) discord/\(baseline.desktopVersion) "
            + "Chrome/\(baseline.chromiumVersion) Electron/\(baseline.electronVersion) "
            + "Safari/\(webKit)"

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif

        var properties: [String: JSONScalar] = [
            "os": .string("Mac OS X"),
            "browser": .string("Discord Client"),
            "release_channel": .string("stable"),
            "client_version": .string(baseline.desktopVersion),
            "os_version": .string(osVersion),
            "os_arch": .string(architecture),
            "app_arch": .string(architecture),
            "system_locale": .string(Locale.preferredLanguages.first ?? "en-US"),
            "has_client_mods": .bool(false),
            "browser_user_agent": .string(userAgent),
            "browser_version": .string(baseline.electronVersion),
            "client_build_number": .number(Double(baseline.webBuildNumber)),
            "native_build_number": .number(Double(baseline.nativeBuildNumber)),
            "client_event_source": .null,
        ]
        properties["client_launch_id"] = .string(UUID().uuidString.lowercased())
        identifyProperties = properties

        // Base64 of the JSON object, sorted so two runs of the same client
        // produce byte-identical headers.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        superProperties = (try? encoder.encode(properties))?.base64EncodedString() ?? ""
    }

    /// Applies the headers every authenticated request carries.
    public func apply(to request: inout URLRequest, token: String?) {
        if let token { request.setValue(token, forHTTPHeaderField: "Authorization") }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(superProperties, forHTTPHeaderField: "X-Super-Properties")
        request.setValue(locale, forHTTPHeaderField: "X-Discord-Locale")
        request.setValue(timeZone, forHTTPHeaderField: "X-Discord-Timezone")
        request.setValue("bugReporterEnabled", forHTTPHeaderField: "X-Debug-Options")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        request.setValue("https://discord.com/channels/@me", forHTTPHeaderField: "Referer")
    }

    public var apiBase: URL {
        URL(string: "https://discord.com/api/v\(baseline.apiVersion)")!
    }
}

/// A JSON scalar, for the handful of places a heterogeneous object has to be
/// built by hand.
///
/// Deliberately not a full recursive `JSONValue`: the only structures this app
/// builds by hand are flat property bags, and a recursive value type invites
/// hand-decoding of payloads that should be `Codable` structs.
public enum JSONScalar: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers encode as integers. Discord's build number arriving
            // as `587597.0` is a different value to their parser than `587597`.
            if value == value.rounded(), abs(value) < 9e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        self = .string(try container.decode(String.self))
    }
}
