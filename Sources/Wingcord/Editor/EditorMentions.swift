import AppKit
import WingcordCore

/// A mention written into a field, as the raw token the field holds and the
/// message sends — `<@id>`, `<@&id>`, `<#id>`, `<@$id>`, `<t:…>`.
///
/// **The text stays the token.** Discord's box shows a chip where a mention
/// was picked; here the chip is painted over the token's place and the token
/// is what is typed, saved as a draft and sent — so the draft, the triggers
/// and the send path keep working on one plain string, as `MarkdownEditor`
/// promises.
nonisolated enum EditorMention: Hashable, Sendable {
    case user(UserID)
    case role(RoleID)
    case channel(ChannelID)
    case game(ApplicationID)
    case timestamp(Date, TimestampStyle)

    /// Every token in the text, by UTF-16 range, outside the ranges given —
    /// code, where Discord writes a token as itself.
    static func scan(_ text: String, excluding code: [NSRange] = []) -> [(range: NSRange, mention: EditorMention)] {
        guard text.contains("<") else { return [] }
        let string = text as NSString
        var found: [(NSRange, EditorMention)] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let range = match.range
            guard !code.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            if match.range(at: 1).location != NSNotFound {
                let sigil = string.substring(with: match.range(at: 1))
                guard let value = UInt64(string.substring(with: match.range(at: 2))) else { continue }
                let mention: EditorMention = switch sigil {
                case "@&": .role(RoleID(rawValue: value))
                case "@$": .game(ApplicationID(rawValue: value))
                case "#": .channel(ChannelID(rawValue: value))
                default: .user(UserID(rawValue: value))
                }
                found.append((range, mention))
            } else if let seconds = Double(string.substring(with: match.range(at: 3))) {
                let styleRange = match.range(at: 4)
                let style = styleRange.location == NSNotFound
                    ? .shortDateTime
                    : string.substring(with: styleRange).first.flatMap(TimestampStyle.init(rawValue:)) ?? .shortDateTime
                found.append((range, .timestamp(Date(timeIntervalSince1970: seconds), style)))
            }
        }
        return found
    }

    /// Discord's own shapes: a person (with the old `!` form), a role, a game
    /// and a channel by id; a moment by second, with an optional style.
    private static let pattern = try! NSRegularExpression(
        pattern: #"<(@!?|@&|@\$|#)(\d{1,20})>|<t:(-?\d{1,17})(?::([tTdDfFsSR]))?>"#
    )
}

/// How a token is drawn in its place: its words, their ink and the plate.
struct EditorChip: Equatable {
    var label: String
    var ink: NSColor
    var fill: NSColor
}

/// One chip's place in the field — what the text view paints over.
struct EditorChipPlacement: Equatable {
    var range: NSRange
    var chip: EditorChip
}

/// **A chip is one thing to the caret.** The token under it is many
/// characters, and a caret parked inside one — or a delete that takes its last
/// character — would leave half a token showing as text. Discord's box treats
/// a mention as a single character; these two rules are how a plain string
/// does the same.
nonisolated enum EditorMentionAtoms {

    /// Where a selection may rest: never inside a chip. A caret that lands in
    /// one moves on through it the way it was going — or to the nearer edge
    /// for a click — and a selection reaching into one takes all of it.
    static func snap(_ proposed: NSRange, from old: NSRange, around atoms: [NSRange]) -> NSRange {
        if proposed.length == 0 {
            let location = proposed.location
            guard let atom = atoms.first(where: { $0.location < location && location < NSMaxRange($0) })
            else { return proposed }
            let end = NSMaxRange(atom)
            let target: Int = if location > old.location {
                end
            } else if location < old.location {
                atom.location
            } else {
                location - atom.location <= end - location ? atom.location : end
            }
            return NSRange(location: target, length: 0)
        }
        return expand(proposed, around: atoms)
    }

    /// An edit's range grown to take whole chips: one that reaches into a chip
    /// takes all of it, which is how a delete removes a mention at once.
    static func expand(_ range: NSRange, around atoms: [NSRange]) -> NSRange {
        guard range.length > 0 else { return range }
        var result = range
        for atom in atoms where NSIntersectionRange(atom, result).length > 0 {
            result = NSUnionRange(result, atom)
        }
        return result
    }
}
