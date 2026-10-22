import Foundation

// MARK: - Streamer Mode
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D21). Discord's `StreamerModeStore`, read
// out of build 643186: one switch, a second that flips it with the streaming
// software, and five things it does while on — each its own choice, each
// default as Discord's is:
//
//   {enabled: false, autoToggle: true, hideInstantInvites: true,
//    hidePersonalInformation: true, disableSounds: true,
//    disableNotifications: true, disabledOverlayWidgets: [],
//    enableContentProtection: false}
//
// and every getter but `enabled` is `this.enabled && _.option` — an option
// means nothing while the mode is off. `RUNNING_STREAMER_TOOLS_CHANGE` sets
// `enabled` to whether any are running, whatever it was, when the automatic
// switch is on.
//
// Kept on this Mac, as Discord keeps it (a persisted store per account, never
// the settings blob): it describes what this machine's screen shows.

public struct StreamerModeSettings: Hashable, Sendable, Codable {
    /// Discord's "Enable Streamer Mode".
    public var isEnabled = false
    /// "Automatically enable Streamer Mode if OBS or XSplit are running".
    public var turnsOnWithStreamingSoftware = true
    /// "Hide my personal information, such as email, connected accounts, and
    /// notes".
    public var hidesPersonalInformation = true
    /// "Hide invite links to my Discord servers".
    public var hidesInviteLinks = true
    /// "Disable all sound effects".
    public var disablesSounds = true
    /// "Disable notifications".
    public var disablesNotifications = true
    /// "Hide Discord Window from Screen Capture" — off by default, as
    /// Discord's is: a reader capturing Wingcord on purpose should not find it
    /// missing from their own recording.
    public var hidesWindowsFromCapture = false
    /// "Hide overlay widgets": which ones go while the mode is on.
    public var hiddenOverlayWidgets: Set<OverlayWidgetKind> = []

    public init() {}

    // MARK: What it does right now
    //
    // Discord's getters: an option means nothing while the mode is off.

    public var hidesPersonalInformationNow: Bool { isEnabled && hidesPersonalInformation }
    public var hidesInviteLinksNow: Bool { isEnabled && hidesInviteLinks }
    public var disablesSoundsNow: Bool { isEnabled && disablesSounds }
    public var disablesNotificationsNow: Bool { isEnabled && disablesNotifications }
    public var hidesWindowsFromCaptureNow: Bool { isEnabled && hidesWindowsFromCapture }
    public var hiddenOverlayWidgetsNow: Set<OverlayWidgetKind> {
        isEnabled ? hiddenOverlayWidgets : []
    }

    /// The streaming software came or went.
    ///
    /// **Discord's rule, whole:** with the automatic switch on, the mode is
    /// on exactly while something is running — so a mode turned on by hand
    /// goes off when the software quits, and one turned off by hand comes back
    /// when it starts. Returns whether anything moved.
    @discardableResult
    public mutating func streamingSoftwareChanged(running: Bool) -> Bool {
        guard turnsOnWithStreamingSoftware, isEnabled != running else { return false }
        isEnabled = running
        return true
    }

    // MARK: Reading old builds

    private enum CodingKeys: String, CodingKey {
        case isEnabled, turnsOnWithStreamingSoftware, hidesPersonalInformation, hidesInviteLinks
        case disablesSounds, disablesNotifications, hidesWindowsFromCapture, hiddenOverlayWidgets
    }

    /// **Lenient**, so an option added later reads as its default rather than
    /// failing the whole decode and switching the mode off.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = StreamerModeSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fresh.isEnabled
        turnsOnWithStreamingSoftware = try container.decodeIfPresent(
            Bool.self, forKey: .turnsOnWithStreamingSoftware
        ) ?? fresh.turnsOnWithStreamingSoftware
        hidesPersonalInformation = try container.decodeIfPresent(
            Bool.self, forKey: .hidesPersonalInformation
        ) ?? fresh.hidesPersonalInformation
        hidesInviteLinks = try container.decodeIfPresent(Bool.self, forKey: .hidesInviteLinks)
            ?? fresh.hidesInviteLinks
        disablesSounds = try container.decodeIfPresent(Bool.self, forKey: .disablesSounds)
            ?? fresh.disablesSounds
        disablesNotifications = try container.decodeIfPresent(Bool.self, forKey: .disablesNotifications)
            ?? fresh.disablesNotifications
        hidesWindowsFromCapture = try container.decodeIfPresent(
            Bool.self, forKey: .hidesWindowsFromCapture
        ) ?? fresh.hidesWindowsFromCapture
        // Unknown widget names — one a later build added — are dropped rather
        // than failing the set.
        let names = try container.decodeIfPresent([String].self, forKey: .hiddenOverlayWidgets) ?? []
        hiddenOverlayWidgets = Set(names.compactMap(OverlayWidgetKind.init(rawValue:)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(turnsOnWithStreamingSoftware, forKey: .turnsOnWithStreamingSoftware)
        try container.encode(hidesPersonalInformation, forKey: .hidesPersonalInformation)
        try container.encode(hidesInviteLinks, forKey: .hidesInviteLinks)
        try container.encode(disablesSounds, forKey: .disablesSounds)
        try container.encode(disablesNotifications, forKey: .disablesNotifications)
        try container.encode(hidesWindowsFromCapture, forKey: .hidesWindowsFromCapture)
        try container.encode(hiddenOverlayWidgets.map(\.rawValue).sorted(), forKey: .hiddenOverlayWidgets)
    }
}

// MARK: - What counts as streaming software

/// An application whose running turns Streamer Mode on.
///
/// Discord's list is OBS and XSplit. XSplit has no Mac build; the Mac's
/// other broadcasters take its place. Matched by bundle identifier, and by
/// name for a build that ships under another identifier.
public struct StreamingSoftware: Hashable, Sendable {
    public var name: String
    public var bundleIdentifiers: Set<String>
    public var names: Set<String>

    public static let known: [StreamingSoftware] = [
        StreamingSoftware(
            name: "OBS",
            bundleIdentifiers: ["com.obsproject.obs-studio"],
            names: ["OBS", "OBS Studio"]
        ),
        StreamingSoftware(
            name: "Streamlabs",
            bundleIdentifiers: ["com.streamlabs.slobs"],
            names: ["Streamlabs Desktop", "Streamlabs OBS", "Streamlabs"]
        ),
        StreamingSoftware(
            name: "Ecamm Live",
            bundleIdentifiers: ["com.ecamm.EcammLive"],
            names: ["Ecamm Live"]
        ),
        StreamingSoftware(
            name: "XSplit",
            bundleIdentifiers: [],
            names: ["XSplit Broadcaster", "XSplit"]
        ),
    ]

    /// The known software an application is, if it is one.
    public static func match(bundleIdentifier: String?, name: String?) -> StreamingSoftware? {
        known.first { software in
            if let bundleIdentifier, software.bundleIdentifiers.contains(bundleIdentifier) {
                return true
            }
            if let name, software.names.contains(name) { return true }
            return false
        }
    }
}

// MARK: - What it hides, and how

public enum StreamerModeMask {
    /// An email address as Streamer Mode draws it: nothing of it left.
    ///
    /// **Not the domain kept**, as some clients do. "@gmail.com" is harmless;
    /// a work domain is half of somebody's address and the name of their
    /// employer.
    public static func email(_ address: String) -> String {
        address.isEmpty ? "" : String(repeating: "•", count: 12)
    }

    /// A phone number: its last two digits, which is what a reader needs to
    /// recognise their own and nobody watching can use.
    public static func phone(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        guard digits.count > 2 else { return String(repeating: "•", count: 8) }
        return String(repeating: "•", count: 8) + digits.suffix(2)
    }

    /// An invite link with its code withheld: "discord.gg/••••••••".
    public static func invite(_ link: String) -> String {
        guard let slash = link.lastIndex(of: "/") else { return code(link) }
        return String(link[...slash]) + code(link)
    }

    /// A bare invite code, withheld. Always eight dots, so the length of the
    /// code is not given away either.
    public static func code(_ code: String) -> String {
        String(repeating: "•", count: 8)
    }
}
