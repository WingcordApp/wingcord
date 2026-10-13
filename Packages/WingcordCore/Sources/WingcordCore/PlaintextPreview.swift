import Foundation

/// Discord's preview of a text file in a message (`684519`'s `eC` and `eS`):
/// which files have one, what is fetched, how it is cleaned, and what the
/// card says about what it is not showing.
public enum PlaintextPreview {

    // MARK: Which files

    /// highlight.js's languages and their aliases, in Discord's order
    /// (`639169.Q`, whose two repeats — `ml`, `ls` — a set drops). The
    /// language picker lists them; a file whose name ends in one is previewed.
    public static let languages: [String] = [
        "1c", "4d", "abnf", "accesslog", "ada", "arduino", "ino", "armasm", "arm", "avrasm",
        "actionscript", "as", "ass", "ssa", "alan", "ansi", "i", "log", "ln", "angelscript", "asc",
        "apache", "apacheconf", "applescript", "osascript", "arcade", "asciidoc", "adoc",
        "aspectj", "autohotkey", "autoit", "awk", "mawk", "nawk", "gawk", "bash", "sh", "zsh",
        "basic", "bbcode", "blade", "bnf", "brainfuck", "bf", "csharp", "cs", "c", "h", "cpp",
        "hpp", "cc", "hh", "c++", "h++", "cxx", "hxx", "cal", "cos", "cls", "cmake", "cmake.in",
        "coq", "csp", "css", "csv", "capnproto", "capnp", "chaos", "kaos", "chapel", "chpl",
        "cisco", "clojure", "clj", "coffeescript", "coffee", "cson", "iced", "cpc", "crmsh", "crm",
        "pcmk", "crystal", "cr", "cypher", "d", "dns", "zone", "bind", "dos", "bat", "cmd", "dart",
        "delphi", "dpr", "dfm", "pas", "pascal", "freepascal", "lazarus", "lpr", "lfm", "diff",
        "patch", "django", "jinja", "dockerfile", "docker", "dsconfig", "dts", "dust", "dst",
        "dylan", "ebnf", "elixir", "ex", "elm", "erlang", "erl", "extempore", "xtlang", "xtm",
        "fsharp", "fs", "fix", "fortran", "f90", "f95", "gcode", "nc", "gams", "gms", "gauss",
        "gss", "godot", "gdscript", "gherkin", "gn", "gni", "go", "golang", "gf", "golo",
        "gololang", "gradle", "groovy", "xml", "html", "xhtml", "rss", "atom", "xjb", "xsd", "xsl",
        "plist", "svg", "http", "https", "haml", "handlebars", "hbs", "html.hbs",
        "html.handlebars", "haskell", "hs", "haxe", "hx", "hy", "hylang", "ini", "toml", "inform7",
        "i7", "irpf90", "json", "java", "jsp", "javascript", "js", "jsx", "jolie", "iol", "ol",
        "julia", "julia-repl", "kotlin", "kt", "tex", "leaf", "lean", "lasso", "ls", "lassoscript",
        "less", "ldif", "lisp", "livecodeserver", "livescript", "lock", "lua", "makefile", "mk",
        "mak", "make", "markdown", "md", "mkdown", "mkd", "mathematica", "mma", "wl", "matlab",
        "maxima", "mel", "mercury", "mirc", "mrc", "mizar", "mojolicious", "monkey", "moonscript",
        "moon", "n1ql", "nsis", "never", "nginx", "nginxconf", "nim", "nimrod", "nix", "ocl",
        "ocaml", "ml", "objectivec", "mm", "objc", "obj-c", "obj-c++", "objective-c++", "glsl",
        "openscad", "scad", "ruleslanguage", "oxygene", "pf", "pf.conf", "php", "php3", "php4",
        "php5", "php6", "php7", "parser3", "perl", "pl", "pm", "plaintext", "txt", "text", "pony",
        "pgsql", "postgres", "postgresql", "powershell", "ps", "ps1", "processing", "prolog",
        "properties", "proto", "protobuf", "puppet", "pp", "python", "py", "gyp", "profile",
        "python-repl", "pycon", "k", "kdb", "qml", "r", "cshtml", "razor", "razor-cshtml",
        "reasonml", "re", "redbol", "rebol", "red", "red-system", "rib", "rsl", "graph",
        "instances", "robot", "rf", "rpm-specfile", "rpm", "spec", "rpm-spec", "specfile", "ruby",
        "rb", "gemspec", "podspec", "thor", "irb", "rust", "rs", "SAS", "sas", "scss", "sql",
        "p21", "step", "stp", "scala", "scheme", "scilab", "sci", "shexc", "shell", "console",
        "smali", "smalltalk", "st", "sml", "solidity", "sol", "stan", "stanfuncs", "stata",
        "iecst", "scl", "structured-text", "stylus", "styl", "subunit", "supercollider", "sc",
        "srt", "svelte", "swift", "tcl", "tk", "terraform", "tf", "hcl", "tap", "thrift", "tp",
        "tsql", "ttml", "twig", "craftcms", "typescript", "ts", "tsx", "unicorn-rails-log",
        "vbnet", "vb", "vba", "vbscript", "vbs", "vhdl", "vala", "verilog", "v", "vim", "vtt",
        "axapta", "x++", "x86asm", "xl", "tao", "xquery", "xpath", "xq", "yml", "yaml", "zephir",
        "zep",
    ]

    private static let languageSet = Set(languages)

    /// The languages Render Markdown applies to.
    public static let markdownLanguages: Set<String> = ["markdown", "md", "mkd", "mkdown"]

    /// Whether a file is shown as a preview rather than a file card — the part
    /// of its name after the last `.`, *as written*, is a language
    /// (`639169.C`). Discord's check has no case folding: `notes.TXT` is a file.
    public static func isPreviewable(filename: String) -> Bool {
        languageSet.contains(language(ofFilename: filename))
    }

    /// The language a preview starts in: that same part of the name, the whole
    /// name when it has no `.`.
    public static func language(ofFilename filename: String) -> String {
        guard let dot = filename.lastIndex(of: ".") else { return filename }
        return String(filename[filename.index(after: dot)...])
    }

    // MARK: Fetching

    /// The bytes asked for — Discord's `Range: bytes=0-50000`.
    public static let rangeHeader = "bytes=0-50000"

    /// How much of the file the fetch did not bring: the total after `/` in
    /// `Content-Range` less `Content-Length` (Discord reads a missing length
    /// as 1), and none when there is no total to read — a server that ignored
    /// the range sent everything.
    public static func bytesLeft(contentRange: String?, contentLength: String?) -> Int {
        let parts = (contentRange ?? "0").split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1, let total = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return 0 }
        return total - (Int(contentLength ?? "1") ?? 0)
    }

    /// The text of what was fetched, decoded as Discord's `TextDecoder` is: by
    /// the content type's `charset=`, UTF-8 without one. A charset nobody
    /// knows reads as UTF-8 for a `text` type or a name with `utf` in it, and
    /// otherwise is no preview at all. With bytes left, the last character is
    /// dropped — the cut may have fallen inside it — and the rest is cleaned.
    public static func text(of data: Data, contentType: String?, bytesLeft: Int) -> String? {
        let charset = contentType?.components(separatedBy: "charset=").last ?? "utf-8"
        var encoding = String.Encoding.utf8
        if let contentType, contentType.contains("charset=") {
            let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: " \"';")).lowercased()
            let known = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if known != kCFStringEncodingInvalidId {
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(known))
            } else if !(contentType.hasPrefix("text") || name.contains("utf")) {
                return nil
            }
        }
        var text = String(decoding: data, as: UTF8.self)
        if encoding != .utf8 {
            guard let decoded = String(data: data, encoding: encoding) else { return nil }
            text = decoded
        }
        if bytesLeft != 0, !text.isEmpty { text.removeLast() }
        return sanitise(text)
    }

    /// The fillers Discord removes besides the categories (`417964`).
    private static let fillers: Set<Unicode.Scalar> = ["\u{034F}", "\u{17B4}", "\u{17B5}", "\u{1160}", "\u{3164}", "\u{FFA0}"]

    /// Discord's `sJ`: format characters, line and paragraph separators,
    /// controls but the newline and the tab — so a CRLF file's returns go —
    /// spaces but the plain one, and six invisible fillers, all removed.
    public static func sanitise(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !removes(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func removes(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .lineSeparator, .paragraphSeparator: true
        case .control: scalar != "\n" && scalar != "\t"
        case .spaceSeparator: scalar != " "
        default: fillers.contains(scalar)
        }
    }

    // MARK: The card

    /// The lines a card shows.
    public static let collapsedLines = 6
    public static let expandedLines = 100

    /// What a card shows of a file, and what it says about the rest.
    public struct Excerpt: Equatable, Sendable {
        /// The lines shown.
        public var text: String
        /// What follows them: `...`, and the lines or the bytes not shown —
        /// empty when the card shows the end, or the fold hides the rest.
        public var notice: String
        /// How many lines were fetched.
        public var lineCount: Int
        /// Whether Expand / Collapse is offered.
        public var offersToggle: Bool
    }

    /// Discord's `eS`: six lines folded, a hundred open. Counts and sizes are
    /// written in `locale`, as Discord writes them in the app's.
    public static func excerpt(
        of contents: String,
        isExpanded: Bool,
        bytesLeft: Int,
        locale: Locale = .current
    ) -> Excerpt {
        let lines = contents.components(separatedBy: "\n")
        let shown = isExpanded ? expandedLines : collapsedLines
        let isWhole = bytesLeft == 0
        var notice = ""
        if isWhole, isExpanded, lines.count > shown {
            notice = "\n... (\(linesLabel(lines.count - shown, locale: locale)))"
        } else if !isWhole {
            notice = "... (\(fileSize(bytesLeft, locale: locale)) left)"
        }
        return Excerpt(
            text: lines.prefix(shown).joined(separator: "\n"),
            notice: notice,
            lineCount: lines.count,
            offersToggle: isExpanded || shown < lines.count
        )
    }

    /// View whole file's ending: everything fetched, then what was not.
    public static func wholeFileNotice(bytesLeft: Int, locale: Locale = .current) -> String {
        bytesLeft > 0 ? "... (\(fileSize(bytesLeft, locale: locale)) left)" : ""
    }

    /// Expand / Collapse's words: "Expand (12 lines)", or — when the fetch did
    /// not reach the end — "Expand (More than 1,204 lines)".
    public static func toggleTitle(
        isExpanded: Bool,
        lineCount: Int,
        isWholeFile: Bool,
        locale: Locale = .current
    ) -> String {
        let lines = linesLabel(lineCount, locale: locale)
        let count = isWholeFile ? lines : "More than \(lines)"
        return "\(isExpanded ? "Collapse" : "Expand") (\(count))"
    }

    /// Discord's "{n} lines", one line or many.
    static func linesLabel(_ count: Int, locale: Locale) -> String {
        count == 1 ? "1 line" : "\(count.formatted(.number.locale(locale))) lines"
    }

    /// Discord's size for a preview (`255438.up`): whole kilobytes, rounded
    /// up, to a megabyte; whole megabytes, rounded up, to a thousand; then
    /// gigabytes to one place — all in thousands, not 1,024s.
    public static func fileSize(_ bytes: Int, locale: Locale = .current) -> String {
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        let kilobytes = Double(bytes) / 1000
        guard kilobytes / 1000 >= 1 else { return "\(Int(kilobytes.rounded(.up)).formatted(number)) KB" }
        let megabytes = (kilobytes / 1000).rounded(.up)
        guard megabytes >= 1000 else { return "\(Int(megabytes).formatted(number)) MB" }
        let gigabytes = (megabytes / 1000 * 10).rounded() / 10
        return "\(gigabytes.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) GB"
    }
}
