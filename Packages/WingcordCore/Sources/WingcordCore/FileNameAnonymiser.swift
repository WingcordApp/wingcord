import Foundation

/// Vencord's AnonymiseFileNames — its `anonymise`, which renames each file as
/// its upload begins: a new name before what the old one ended with, which is
/// a `.tar.` archive's two parts, or the last `.` onwards, or nothing.
public enum FileNameAnonymiser {
    /// The plugin's three methods, in its settings' order and with its labels.
    public enum Method: String, CaseIterable, Identifiable, Sendable {
        case randomCharacters
        case consistent
        case timestamp

        public var id: Self { self }

        public var title: String {
            switch self {
            case .randomCharacters: "Random Characters"
            case .consistent: "Consistent"
            case .timestamp: "Timestamp"
            }
        }
    }

    /// The plugin's alphabet: the digits, and the consonants least like them.
    static let alphabet = Array("0123456789bdfhjkmnpqrstvwxz")

    /// The new name.
    ///
    /// - Parameters:
    ///   - length: Random Characters' count; none below zero, as the plugin's
    ///     `Array.from` makes none.
    ///   - consistentName: Consistent's name, used as it is — an empty one
    ///     leaves the ending alone, as the plugin's does.
    ///   - now: Timestamp's moment, written in whole milliseconds since 1970
    ///     as `Date.now()` is.
    public static func anonymise(
        _ filename: String,
        method: Method,
        length: Int,
        consistentName: String,
        now: Date,
        using generator: inout some RandomNumberGenerator
    ) -> String {
        let ending = ending(of: filename)
        switch method {
        case .randomCharacters:
            let characters = (0..<max(0, length)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
            return String(characters) + ending
        case .consistent:
            return consistentName + ending
        case .timestamp:
            return String(Int64((now.timeIntervalSince1970 * 1000).rounded(.down))) + ending
        }
    }

    /// What a new name keeps: the plugin's `/\.tar\.\w+$/` where it matches —
    /// case-sensitive, and `\w` is ASCII's letters, digits and underscore —
    /// else everything from the last `.`, else nothing.
    public static func ending(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: ".") else { return "" }
        let last = filename[filename.index(after: dot)...]
        if !last.isEmpty, last.allSatisfy(isWordCharacter), filename[..<dot].hasSuffix(".tar") {
            return String(filename[filename.index(dot, offsetBy: -4)...])
        }
        return String(filename[dot...])
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
}
