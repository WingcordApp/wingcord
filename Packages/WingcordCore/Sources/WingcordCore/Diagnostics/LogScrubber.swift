import CryptoKit
import Foundation

/// Takes out of a line what must never leave the Mac (docs/BUG-REPORTING.md §2).
///
/// **The second of two guards.** The first is the log call itself, which takes
/// only values the code chose to print (`LogMessage`): a name or a message's
/// words cannot be recognised by their shape, so they are kept out at the
/// source. This pass catches what has a shape — and runs twice, as each line is
/// written and again over the whole bundle when a report is made:
///
/// - a Discord token, a JWT, and the value after `token`, `password`,
///   `authorization`, `session_id` and their kind, wherever the line spells the
///   key out — `token=…`, `"token":"…"`, `Authorization: …`;
/// - an e-mail address;
/// - an IP address, v4 or v6 — a voice server's, a discovery answer, a candidate;
/// - a URL's query and fragment (a CDN link's `ex`/`is`/`hm` signature, a
///   search's words), its credentials, an IP for a host, and an attachment's
///   file name;
/// - a snowflake, as a short hash under this install's own salt — so one
///   channel reads as one name across a report, and the name is not the id;
/// - a hex string of 32 characters or more — a session id, a key, a hash;
/// - a home folder, as `~`.
///
/// **One pass over the bytes, by hand, rather than a set of regular
/// expressions.** It runs on every line written, and Swift's `Regex` costs tens
/// of microseconds a match on short strings (INVARIANTS §2, "a `Regex` literal
/// is compiled where it is written") — the whole of this pass is a few
/// microseconds a line.
public struct LogScrubber: Sendable {
    /// The install's secret, mixed into every hash. Without it a hash could be
    /// reversed by hashing candidate ids.
    public let salt: [UInt8]
    /// This user's home folder, replaced by `~` wherever it appears.
    public let home: String?

    public init(salt: [UInt8], home: String? = NSHomeDirectory()) {
        self.salt = salt
        self.home = home.flatMap { $0.count > 1 ? $0 : nil }
    }

    /// A scrubber with a salt nobody keeps — for a line written before the
    /// install's own salt is read, and for tests.
    public static func ephemeral() -> LogScrubber {
        var generator = SystemRandomNumberGenerator()
        return LogScrubber(salt: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: Hashes

    /// `#` and eight hex digits: the salted SHA-256 of the id, cut short.
    ///
    /// Thirty-two bits is plenty inside one report — a thousand distinct ids
    /// collide about once in ten thousand reports — and short enough to read.
    public func hash(_ raw: UInt64) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        withUnsafeBytes(of: raw.littleEndian) { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        var text = "#"
        text.reserveCapacity(9)
        for byte in digest.prefix(4) {
            text.append(Self.hexDigit(byte >> 4))
            text.append(Self.hexDigit(byte & 0x0F))
        }
        return text
    }

    public func hash<Tag>(_ id: Snowflake<Tag>) -> String { hash(id.rawValue) }

    // MARK: The pass

    public func scrub(_ text: String) -> String {
        var source = text
        if let home, source.contains(home) {
            source = source.replacingOccurrences(of: home, with: "~")
        }
        let bytes = Array(source.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 16)

        var index = 0
        // A sensitive key was just read ("token:" or "token" then ":"), so the
        // next value is replaced whatever it looks like.
        var valueIsSecret = false
        // The last run was a sensitive key spelled alone — JSON's `"token"` —
        // and is waiting for its `:` to become a key.
        var keyAwaitsSeparator = false

        while index < bytes.count {
            let byte = bytes[index]
            if Self.isDelimiter(byte) {
                output.append(byte)
                index += 1
                continue
            }
            var end = index
            while end < bytes.count, !Self.isDelimiter(bytes[end]) { end += 1 }
            let run = bytes[index..<end]
            index = end

            if Self.isSeparatorOnly(run) {
                output.append(contentsOf: run)
                if keyAwaitsSeparator { valueIsSecret = true }
                keyAwaitsSeparator = false
                continue
            }
            if valueIsSecret {
                output.append(contentsOf: Self.redacted)
                valueIsSecret = false
                keyAwaitsSeparator = false
                continue
            }
            let scrubbed = scrubRun(run)
            output.append(contentsOf: scrubbed.bytes)
            valueIsSecret = scrubbed.opensSecretValue
            keyAwaitsSeparator = scrubbed.isBareSensitiveKey
        }
        return String(decoding: output, as: UTF8.self)
    }

    private struct ScrubbedRun {
        var bytes: [UInt8]
        /// "token:" or "token=" with nothing after it: the next run is the value.
        var opensSecretValue = false
        /// "token" alone, which becomes a key if a ":" or "=" follows.
        var isBareSensitiveKey = false
    }

    private func scrubRun(_ run: ArraySlice<UInt8>) -> ScrubbedRun {
        if Self.isURL(run) {
            return ScrubbedRun(bytes: scrubURL(run))
        }
        if Self.isSensitiveKey(run) {
            return ScrubbedRun(bytes: Array(run), isBareSensitiveKey: true)
        }
        if let last = run.last, last == UInt8(ascii: ":") || last == UInt8(ascii: "="),
           Self.isSensitiveKey(run.dropLast())
        {
            return ScrubbedRun(bytes: Array(run), opensSecretValue: true)
        }
        // A path without its scheme — a REST route — loses its query as a URL
        // does: `/messages/search?content=…` carries what was searched for.
        if let question = run.firstIndex(of: UInt8(ascii: "?")),
           run[run.startIndex..<question].contains(UInt8(ascii: "/"))
        {
            var bytes = scrubRun(run[run.startIndex..<question]).bytes
            bytes.append(contentsOf: Self.queryMark)
            return ScrubbedRun(bytes: bytes)
        }
        if run.contains(UInt8(ascii: "=")) {
            return ScrubbedRun(bytes: scrubPairs(run))
        }
        return ScrubbedRun(bytes: scrubPlain(run))
    }

    /// `a=1&token=xyz`: each pair's value is scrubbed, and a sensitive key's is
    /// replaced outright.
    private func scrubPairs(_ run: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(run.count)
        var first = true
        for pair in run.split(separator: UInt8(ascii: "&"), omittingEmptySubsequences: false) {
            if !first { output.append(UInt8(ascii: "&")) }
            first = false
            guard let equals = pair.firstIndex(of: UInt8(ascii: "=")) else {
                output.append(contentsOf: scrubPlain(pair))
                continue
            }
            let key = pair[pair.startIndex..<equals]
            let value = pair[pair.index(after: equals)...]
            output.append(contentsOf: scrubPlain(key))
            output.append(UInt8(ascii: "="))
            if Self.isSensitiveKey(key) {
                if !value.isEmpty { output.append(contentsOf: Self.redacted) }
            } else {
                output.append(contentsOf: scrubPlain(value))
            }
        }
        return output
    }

    // MARK: Shapes inside a run

    /// Everything that is not a URL or a key: whole-run shapes first, then the
    /// shapes that sit inside a run.
    private func scrubPlain(_ run: ArraySlice<UInt8>) -> [UInt8] {
        guard !run.isEmpty else { return [] }
        if let email = Self.emailRange(in: run) {
            // `mailto:a@b.com` — the address goes, what is around it is read on.
            var output = scrubPlain(run[run.startIndex..<email.lowerBound])
            output.append(contentsOf: Self.emailMark)
            output.append(contentsOf: scrubPlain(run[email.upperBound...]))
            return output
        }
        if Self.isToken(run) { return Self.tokenMark }
        if Self.isIPv6(run) { return Self.ipMark }
        return scrubInside(run)
    }

    /// IPv4 addresses, home folders, snowflakes and long hex, wherever they sit
    /// in a run.
    private func scrubInside(_ run: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(run.count)
        var index = run.startIndex
        let end = run.endIndex

        while index < end {
            let byte = run[index]

            if byte == UInt8(ascii: "/"), Self.hasPrefix(Self.usersPrefix, in: run, at: index) {
                output.append(UInt8(ascii: "~"))
                var skip = index + Self.usersPrefix.count
                while skip < end, run[skip] != UInt8(ascii: "/") { skip += 1 }
                index = skip
                continue
            }

            guard Self.isAlphanumeric(byte) else {
                output.append(byte)
                index += 1
                continue
            }

            let startsWord = index == run.startIndex || !Self.isAlphanumeric(run[index - 1])
            if startsWord, Self.isDigit(byte),
               index == run.startIndex || run[index - 1] != UInt8(ascii: "."),
               let length = Self.ipv4Length(in: run, at: index)
            {
                output.append(contentsOf: Self.ipMark)
                index += length
                continue
            }

            var wordEnd = index
            while wordEnd < end, Self.isAlphanumeric(run[wordEnd]) { wordEnd += 1 }
            let word = run[index..<wordEnd]
            if startsWord {
                if word.allSatisfy(Self.isDigit), (17...20).contains(word.count),
                   let value = UInt64(String(decoding: word, as: UTF8.self))
                {
                    output.append(contentsOf: Array(hash(value).utf8))
                } else if word.count >= 32, word.allSatisfy(Self.isHexDigit) {
                    output.append(contentsOf: Self.hexMark)
                } else {
                    output.append(contentsOf: word)
                }
            } else {
                output.append(contentsOf: word)
            }
            index = wordEnd
        }
        return output
    }

    // MARK: URLs

    private func scrubURL(_ run: ArraySlice<UInt8>) -> [UInt8] {
        guard let schemeEnd = Self.find(Self.schemeSeparator, in: run) else { return scrubPlain(run) }
        var output = Array(run[run.startIndex..<schemeEnd])
        output.append(contentsOf: Self.schemeSeparator)

        let afterScheme = schemeEnd + Self.schemeSeparator.count
        var authorityEnd = afterScheme
        while authorityEnd < run.endIndex,
              !Self.endsAuthority(run[authorityEnd])
        {
            authorityEnd += 1
        }
        var authority = run[afterScheme..<authorityEnd]
        // Credentials in a URL are a secret by definition.
        if let at = authority.lastIndex(of: UInt8(ascii: "@")) {
            authority = authority[authority.index(after: at)...]
        }
        output.append(contentsOf: scrubHost(authority))

        var pathEnd = authorityEnd
        while pathEnd < run.endIndex,
              run[pathEnd] != UInt8(ascii: "?"), run[pathEnd] != UInt8(ascii: "#")
        {
            pathEnd += 1
        }
        let path = run[authorityEnd..<pathEnd]
        let segments = path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        let isAttachment = segments.contains { segment in
            segment.elementsEqual("attachments".utf8) || segment.elementsEqual("ephemeral-attachments".utf8)
        }
        for (position, segment) in segments.enumerated() {
            if position > 0 { output.append(UInt8(ascii: "/")) }
            if isAttachment, position == segments.count - 1, !segment.isEmpty {
                output.append(contentsOf: Self.fileMark)
                if let dot = segment.lastIndex(of: UInt8(ascii: ".")),
                   segment.distance(from: dot, to: segment.endIndex) <= 6
                {
                    output.append(contentsOf: segment[dot...])
                }
            } else {
                output.append(contentsOf: scrubPlain(segment))
            }
        }
        if pathEnd < run.endIndex {
            output.append(contentsOf: Self.queryMark)
        }
        return output
    }

    /// A host, with its port kept: an address becomes `<ip>`.
    private func scrubHost(_ authority: ArraySlice<UInt8>) -> [UInt8] {
        if authority.first == UInt8(ascii: "["),
           let close = authority.firstIndex(of: UInt8(ascii: "]"))
        {
            var output = Self.ipMark
            output.append(contentsOf: authority[authority.index(after: close)...])
            return output
        }
        var host = authority
        var port: ArraySlice<UInt8> = []
        if let colon = authority.lastIndex(of: UInt8(ascii: ":")),
           authority[authority.index(after: colon)...].allSatisfy(Self.isDigit)
        {
            host = authority[authority.startIndex..<colon]
            port = authority[colon...]
        }
        if let length = Self.ipv4Length(in: host, at: host.startIndex), length == host.count {
            return Self.ipMark + port
        }
        return Array(host) + port
    }

    // MARK: Whole-run shapes

    static func isURL(_ run: ArraySlice<UInt8>) -> Bool {
        guard let separator = find(schemeSeparator, in: run), separator > run.startIndex else { return false }
        return run[run.startIndex..<separator].allSatisfy { isLetter($0) || $0 == UInt8(ascii: "+") }
    }

    /// Where an address `local@domain.tld` sits in a run, or nil: something
    /// before the at sign, and a dot after it with two letters or more beyond
    /// the last one.
    static func emailRange(in run: ArraySlice<UInt8>) -> Range<Int>? {
        var searchFrom = run.startIndex
        while let at = run[searchFrom...].firstIndex(of: UInt8(ascii: "@")) {
            searchFrom = at + 1
            var start = at
            while start > run.startIndex, isEmailLocal(run[start - 1]) { start -= 1 }
            var end = at + 1
            while end < run.endIndex, isAlphanumeric(run[end]) || run[end] == UInt8(ascii: ".")
                || run[end] == UInt8(ascii: "-")
            {
                end += 1
            }
            // A sentence's full stop after the address is not part of it.
            while end > at + 1, run[end - 1] == UInt8(ascii: ".") { end -= 1 }
            guard start < at, end > at + 1 else { continue }
            let domain = run[(at + 1)..<end]
            guard let dot = domain.lastIndex(of: UInt8(ascii: ".")), dot > domain.startIndex else { continue }
            let tld = domain[(dot + 1)...]
            guard tld.count >= 2, tld.allSatisfy(isLetter) else { continue }
            return start..<end
        }
        return nil
    }

    static func isEmailLocal(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "%") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
    }

    /// A Discord token or a JWT: three base64url parts joined by two dots, long
    /// enough not to be a version number. Also the old `mfa.` tokens.
    static func isToken(_ run: ArraySlice<UInt8>) -> Bool {
        if run.starts(with: "mfa.".utf8), run.count > 40 {
            return run.dropFirst(4).allSatisfy(isBase64URL)
        }
        let parts = run.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        guard parts[0].count >= 20, parts[1].count >= 5, parts[2].count >= 20 else { return false }
        return parts.allSatisfy { $0.allSatisfy(isBase64URL) }
    }

    /// An IPv6 address, optionally in brackets, with a zone or a port.
    ///
    /// Hex groups and colons only, and either a `::` or at least five groups —
    /// so a time of day (`10:15:03`) is not one, and a MAC address, which is
    /// as identifying, is.
    static func isIPv6(_ run: ArraySlice<UInt8>) -> Bool {
        var body = run
        if body.first == UInt8(ascii: "["), let close = body.firstIndex(of: UInt8(ascii: "]")) {
            body = body[body.index(after: body.startIndex)..<close]
        }
        if let zone = body.firstIndex(of: UInt8(ascii: "%")) { body = body[body.startIndex..<zone] }
        let colons = body.count(where: { $0 == UInt8(ascii: ":") })
        guard colons >= 2 else { return false }
        guard body.allSatisfy({ isHexDigit($0) || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") })
        else { return false }
        let hasDoubleColon = find(Array("::".utf8), in: body) != nil
        let groups = body.split(separator: UInt8(ascii: ":")).count
        guard hasDoubleColon || groups >= 5 else { return false }
        // `::` alone, or a run of colons, is punctuation rather than an address.
        return body.contains(where: isHexDigit)
    }

    /// The length of a dotted quad starting at `index`, or nil.
    static func ipv4Length(in run: ArraySlice<UInt8>, at index: Int) -> Int? {
        var cursor = index
        for octet in 0..<4 {
            var digits = 0
            var value = 0
            while cursor < run.endIndex, isDigit(run[cursor]), digits < 3 {
                value = value * 10 + Int(run[cursor] - UInt8(ascii: "0"))
                digits += 1
                cursor += 1
            }
            guard digits > 0, value <= 255 else { return nil }
            if octet < 3 {
                guard cursor < run.endIndex, run[cursor] == UInt8(ascii: ".") else { return nil }
                cursor += 1
            }
        }
        // A fifth part or a longer number means a version string, not an address.
        if cursor < run.endIndex, isAlphanumeric(run[cursor]) { return nil }
        if cursor + 1 < run.endIndex, run[cursor] == UInt8(ascii: "."), isDigit(run[cursor + 1]) { return nil }
        return cursor - index
    }

    /// The keys whose value is a secret whatever it looks like.
    static func isSensitiveKey(_ run: ArraySlice<UInt8>) -> Bool {
        guard run.count >= 2, run.count <= 24 else { return false }
        let key = String(decoding: run, as: UTF8.self).lowercased()
        return sensitiveKeys.contains(key)
    }

    /// Secrets, and the fields of Discord's JSON that hold somebody's words or
    /// names — a protocol dump in detailed logging carries a user object or an
    /// activity, and a name has no shape this pass could recognise otherwise.
    /// Not `message`: that is Discord's own sentence in an error body.
    static let sensitiveKeys: Set<String> = [
        "token", "access_token", "refresh_token", "id_token", "authorization", "bearer",
        "password", "new_password", "passcode", "secret", "client_secret", "secret_key",
        "session_id", "sessionid", "session-id", "ticket", "login_instance_id",
        "fingerprint", "x-fingerprint", "captcha_key", "captcha_rqtoken", "cookie",
        "set-cookie", "email", "phone", "ip", "address", "ip_address", "mfa_code", "totp",
        "username", "global_name", "display_name", "nick", "nickname", "name", "content",
        "bio", "pronouns", "topic", "description", "title", "details",
    ]

    // MARK: Bytes

    /// What separates runs. Not `:`, `=`, `/`, `.`, `@`, `-` or `_` — those
    /// are inside the shapes being looked for.
    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D,
             UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"),
             UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "|"),
             UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"):
            true
        default:
            false
        }
    }

    static func isSeparatorOnly(_ run: ArraySlice<UInt8>) -> Bool {
        !run.isEmpty && run.allSatisfy { $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "=") }
    }

    static func endsAuthority(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "/") || byte == UInt8(ascii: "?") || byte == UInt8(ascii: "#")
    }

    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
    static func isAlphanumeric(_ byte: UInt8) -> Bool { isDigit(byte) || isLetter(byte) }
    static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x66)
    }
    static func isBase64URL(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }

    static func hasPrefix(_ prefix: [UInt8], in run: ArraySlice<UInt8>, at index: Int) -> Bool {
        guard run.endIndex - index >= prefix.count else { return false }
        return run[index..<(index + prefix.count)].elementsEqual(prefix)
    }

    static func find(_ needle: [UInt8], in run: ArraySlice<UInt8>) -> Int? {
        guard !needle.isEmpty, run.count >= needle.count else { return nil }
        var index = run.startIndex
        while index <= run.endIndex - needle.count {
            if run[index] == needle[0], run[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func hexDigit(_ value: UInt8) -> Character {
        Character(Unicode.Scalar(value < 10 ? 0x30 + value : 0x57 + value))
    }

    static let schemeSeparator = Array("://".utf8)
    static let usersPrefix = Array("/Users/".utf8)
    static let redacted = Array("<redacted>".utf8)
    static let emailMark = Array("<email>".utf8)
    static let tokenMark = Array("<token>".utf8)
    static let ipMark = Array("<ip>".utf8)
    static let hexMark = Array("<hex>".utf8)
    static let fileMark = Array("<file>".utf8)
    static let queryMark = Array("?…".utf8)
}
