import Foundation

/// How the member list is arranged — the column head's "Organize by".
///
/// **Discord's friends sidebar has three of these (`nb`, module `763349`), and
/// Roles is this app's**: a server arranged its own list, and that arrangement
/// stays one choice away. Discord has no member-list version of any of it, so in
/// a server the rules below are Discord's friend rules over what a server's list
/// will say.
public enum MemberListOrganization: String, CaseIterable, Identifiable, Sendable {
    /// Live activity at the top, then the server's own groups.
    case activeNow
    /// The server's own groups, as it sends them.
    case roles
    /// One section per game being played, then the server's own groups.
    case game
    /// One section per first letter. Only a list held whole can do this.
    case alphabetical

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .activeNow: "Active Now"
        case .roles: "Roles"
        case .game: "Game"
        case .alphabetical: "Alphabetical"
        }
    }

    /// The sentence under the title in the menu, or nil for none.
    public var summary: String? {
        switch self {
        case .activeNow: "People with live activity at the top"
        case .roles: "The server's own groups"
        case .game: "People organized by the game they're playing now"
        case .alphabetical: nil
        }
    }

    /// The default, Discord's: `O = m.Vj.ACTIVE_NOW`.
    public static let standard = MemberListOrganization.activeNow

    /// What this asks for of a list that cannot do it.
    ///
    /// **A group conversation has no roles, and a list the server won't send
    /// whole cannot be put in order.** Nothing is left blank: the choice falls
    /// back to the one that can be honest.
    public func resolved(hasRoles: Bool, isWhole: Bool) -> MemberListOrganization {
        switch self {
        case .roles: hasRoles ? .roles : .activeNow
        case .alphabetical: isWhole ? .alphabetical : .activeNow
        case .activeNow, .game: self
        }
    }
}

/// Which section a row is in, as something that can be remembered.
public enum MemberSectionKey: Hashable, Sendable {
    case activeNow
    /// Discord's `game:{applicationId ?? name}`.
    case game(String)
    case letter(String)
    case role(RoleID)
    case online
    case offline
    /// The group a list holds before the server has described any.
    case unknown
    /// A search's answers.
    case results
    /// A room inside a section, by channel id. Never folded on its own.
    case voice(String)
    /// The rest of a section after its rooms, by that section's `storageKey`.
    case continuation(String)

    /// How a collapsed section is written down, per server.
    public var storageKey: String {
        switch self {
        case .activeNow: "active_now"
        case .game(let key): "game:\(key)"
        case .letter(let letter): "letter:\(letter)"
        case .role(let id): "role:\(id.rawValue)"
        case .online: "online"
        case .offline: "offline"
        case .unknown: "unknown"
        case .results: "results"
        case .voice(let id): "voice:\(id)"
        case .continuation(let key): "rest:\(key)"
        }
    }
}

/// The order a list the client arranges itself is drawn in — Discord's `fz` and
/// `Ut` (`303911`).
public enum MemberListOrder {

    /// What sorts a name where Discord's collator does: case and accents
    /// ignored, and numbers by value, so `user2` comes before `user10`.
    ///
    /// **A key rather than a comparator**, for the reason `sortedByName` gives:
    /// a locale-aware compare per comparison is an ICU call, and a list is sorted
    /// on every presence flush. Each run of digits is padded to one width, and
    /// after that plain string order is numeric order.
    public static func sortKey(_ name: String) -> String {
        let folded = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        guard folded.contains(where: \.isNumber) else { return folded }
        var key = ""
        key.reserveCapacity(folded.count + 8)
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            key += String(repeating: "0", count: max(0, 12 - digits.count)) + digits
            digits = ""
        }
        for character in folded {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                flush()
                key.append(character)
            }
        }
        flush()
        return key
    }

    /// The section a name files under: its first letter, accents off and upper
    /// case, or `#` for one that doesn't start with a letter — Discord's
    /// `normalize("NFD").match(/^\s*(\p{L})/u)`.
    public static func letter(of name: String) -> String {
        let decomposed = name.decomposedStringWithCanonicalMapping
        let trimmed = decomposed.drop(while: \.isWhitespace)
        guard let first = trimmed.first, first.isLetter else { return otherLetter }
        // A decomposed "Å" is one Character with a combining mark: the letter
        // alone is its first scalar.
        let base = first.unicodeScalars.first.map { String($0) } ?? String(first)
        return base.uppercased()
    }

    /// The section for every name that doesn't start with a letter. It sorts last.
    public static let otherLetter = "#"

    /// Letters in order, `#` last — Discord's `Ut`.
    public static func lettersInOrder(_ letters: some Sequence<String>) -> [String] {
        letters.sorted { lhs, rhs in
            if (lhs == otherLetter) != (rhs == otherLetter) { return rhs == otherLetter }
            return sortKey(lhs) < sortKey(rhs)
        }
    }
}
