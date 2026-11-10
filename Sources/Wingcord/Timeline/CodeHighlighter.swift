import AppKit
import Foundation
import JavaScriptCore
import Synchronization

/// highlight.js — the version Discord ships, 11.11.1, with every language it
/// ships — run in JavaScriptCore, off the main actor, behind Discord's own
/// wrapper (`752238`, decision 9a / REDESIGN.md D1).
///
/// **Discord's engine rather than a lookalike**, because a highlighter's
/// output is its grammars: the same 192 grammars produce the same tokens, and
/// the same tokens through `CodeTokenStyle` produce Discord's colours. The
/// bundle is the official browser build (`@highlightjs/cdn-assets`, BSD-3,
/// `Resources/Highlight/`), each language file concatenated after the core.
///
/// **One context, one serial queue.** A `JSContext` is not safe to use from
/// two threads at once, and highlighting a 50 KB file is tens of milliseconds
/// no frame can spend — so every call hops onto `queue`, and the caller awaits.
/// The context is made on the first call, never at launch: a session that never
/// sees a code file never pays the megabyte.
///
/// What it hands back is **tokens, not HTML**: the emitter's tree flattened to
/// UTF-16 ranges and the scopes over each, so nothing has to parse markup and
/// the colours stay the app's to resolve per room.
nonisolated final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()

    /// A run of code and the highlight.js scopes it sits in, outermost first.
    struct Token: Hashable, Sendable {
        var location: Int
        var length: Int
        var scopes: [String]

        var range: NSRange { NSRange(location: location, length: length) }
    }

    private let queue = DispatchQueue(label: "dev.wingcord.code-highlighter", qos: .userInitiated)
    /// Touched on `queue` only.
    private var engine: Engine?
    private var engineFailed = false
    /// Touched on `queue` only. The engine is freed this long after its last
    /// use: it is 16 MB of JavaScript heap for something that runs for a moment
    /// when a code block appears, and it would otherwise stay for the session.
    private var releaseEngine: DispatchWorkItem?
    private static let engineLifetime: TimeInterval = 120

    private struct CacheKey: Hashable {
        var language: String
        var code: String
    }

    /// The last few answers, so a card scrolled back into view — or opened as
    /// the whole file — draws its colours on its first frame. `Optional`
    /// inside: "highlight.js has nothing for this" is an answer worth keeping.
    private let cache = Mutex<(entries: [CacheKey: [Token]?], order: [CacheKey], inFlight: Set<CacheKey>)>(([:], [], []))
    /// A transcript can hold a few hundred blocks; each answer is a short list
    /// of ranges and the text it is keyed by.
    private static let cacheLimit = 256

    /// Moves whenever an answer lands — what a transcript row laid out while one
    /// of its blocks was still waiting compares against
    /// (`TimelineLayoutEngine.CacheEntry.awaitingHighlightAt`).
    private static let landed = Atomic<UInt64>(0)
    static var revision: UInt64 { landed.load(ordering: .relaxed) }
    /// Posted on the main actor after answers land, at most once a moment, so
    /// a channel of code blocks re-lays its waiting rows once rather than once
    /// per block.
    static let didLand = Notification.Name("CodeHighlighter.didLand")
    private let notifyScheduled = Atomic<Bool>(false)

    // MARK: Asking

    /// The answer already in hand, without waiting: `.some(nil)` when the code
    /// is to be drawn plain, `nil` when it has not been asked yet.
    func cachedTokens(for code: String, language: String) -> [Token]?? {
        let key = CacheKey(language: language.lowercased(), code: code)
        return cache.withLock { $0.entries[key] }
    }

    /// The code's tokens, or nil when it is drawn plain — a language
    /// highlight.js does not know, a text Discord's wrapper refuses, or an
    /// answer with more than two thousand tags.
    func tokens(for code: String, language: String) async -> [Token]? {
        let key = CacheKey(language: language.lowercased(), code: code)
        if let known = cache.withLock({ $0.entries[key] }) { return known }
        let tokens: [Token]? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.highlightOnQueue(code, language: key.language))
            }
        }
        cache.withLock { state in
            state.inFlight.remove(key)
            if state.entries.updateValue(tokens, forKey: key) == nil {
                state.order.append(key)
            }
            while state.order.count > Self.cacheLimit {
                state.entries.removeValue(forKey: state.order.removeFirst())
            }
        }
        Self.landed.add(1, ordering: .relaxed)
        scheduleNotice()
        return tokens
    }

    /// Asks for the code's tokens without waiting — what the transcript's
    /// layout, which cannot wait, does for a block it drew plain. Once per text:
    /// a block already answered or already asked about is left alone.
    func prefetch(_ code: String, language: String) {
        let key = CacheKey(language: language.lowercased(), code: code)
        let isNew = cache.withLock { state -> Bool in
            guard state.entries[key] == nil, !state.inFlight.contains(key) else { return false }
            state.inFlight.insert(key)
            return true
        }
        guard isNew else { return }
        Task.detached(priority: .utility) {
            _ = await CodeHighlighter.shared.tokens(for: code, language: language)
        }
    }

    private func scheduleNotice() {
        guard !notifyScheduled.exchange(true, ordering: .acquiringAndReleasing) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.notifyScheduled.store(false, ordering: .releasing)
            NotificationCenter.default.post(name: CodeHighlighter.didLand, object: nil)
        }
    }

    // MARK: On the queue

    private func highlightOnQueue(_ code: String, language: String) -> [Token]? {
        guard !code.isEmpty, let engine = loadedEngine() else { return nil }
        guard let canonical = engine.canonicalName(language),
              Self.admits(code, canonicalLanguage: canonical)
        else { return nil }
        scheduleEngineRelease()
        return engine.highlight(code, language: language)
    }

    private func scheduleEngineRelease() {
        releaseEngine?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.engine = nil
            self?.releaseEngine = nil
        }
        releaseEngine = work
        queue.asyncAfter(deadline: .now() + Self.engineLifetime, execute: work)
    }

    private func loadedEngine() -> Engine? {
        if let engine { return engine }
        guard !engineFailed else { return nil }
        engine = Engine()
        engineFailed = engine == nil
        return engine
    }

    // MARK: Discord's guards

    /// Whether Discord's wrapper lets highlight.js near the text at all.
    ///
    /// Its `highlight` refuses — and the text is drawn plain — when the text
    /// has fifteen slashes in a row; a line longer than a thousand; a run of
    /// lines holding more than thirty slashes between them (a line that is a
    /// `//` comment, or nothing but slashes, does not end the run); or, for
    /// html, xml, javascript, typescript and handlebars, more than ten
    /// `<script>`s or `` html` ``s once every space is taken out. Each guards a
    /// grammar against input that makes it backtrack for seconds.
    static func admits(_ code: String, canonicalLanguage: String) -> Bool {
        if code.contains(String(repeating: "/", count: 15)) { return false }
        var slashes = 0
        // `"\r\n"` is one `Character` to Swift and two to JavaScript, whose
        // split on `\n` the guard is written against.
        for line in code.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            if line.utf16.count > 1000 { return false }
            let isComment = line.drop(while: \.isJavaScriptWhitespace).hasPrefix("//")
            if !isComment, line.contains(where: { $0 != "/" }) { slashes = 0 }
            slashes += line.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
            if slashes > 30 { return false }
        }
        if Self.scriptGuarded.contains(canonicalLanguage) {
            let squeezed = String(code.unicodeScalars.filter { !$0.isJavaScriptWhitespace }.map(Character.init))
            if Self.scriptMarkers(in: squeezed) > 10 { return false }
        }
        return true
    }

    private static let scriptGuarded: Set<String> = ["html", "xml", "javascript", "typescript", "handlebars"]

    /// `(<script\/?\\?>)|(html\\?`)`, counted.
    private static func scriptMarkers(in text: String) -> Int {
        var count = 0
        var rest = Substring(text)
        while let index = rest.firstIndex(where: { $0 == "<" || $0 == "h" }) {
            rest = rest[index...]
            if let end = match(in: rest, ["<script", "/?", "\\?", ">"]) ?? match(in: rest, ["html", "\\?", "`"]) {
                count += 1
                rest = rest[end...]
            } else {
                rest = rest.dropFirst()
            }
        }
        return count
    }

    /// A tiny matcher for the two patterns above: literal parts, and parts
    /// written `x?` that may be absent.
    private static func match(in text: Substring, _ parts: [String]) -> Substring.Index? {
        var index = text.startIndex
        for part in parts {
            if part.hasSuffix("?") {
                let literal = String(part.dropLast())
                if text[index...].hasPrefix(literal) {
                    index = text.index(index, offsetBy: literal.count)
                }
            } else {
                guard text[index...].hasPrefix(part) else { return nil }
                index = text.index(index, offsetBy: part.count)
            }
        }
        return index
    }

    // MARK: The engine

    /// The context, the bundle evaluated into it, and the two functions this
    /// file asks it for.
    private final class Engine {
        private let context: JSContext
        private let highlightFunction: JSValue
        /// Every name and alias, lowercased, to its language's own name —
        /// Discord's `resolveLanguageName`.
        private let names: [String: String]

        init?() {
            guard let url = Bundle.module.url(forResource: "highlight", withExtension: "js", subdirectory: "Highlight"),
                  let source = try? String(contentsOf: url, encoding: .utf8),
                  let context = JSContext()
            else { return nil }
            context.exceptionHandler = { _, exception in
                DiagnosticLog.trace("highlight", "exception: \(exception?.toString() ?? "?")")
            }
            context.evaluateScript(source, withSourceURL: url)
            context.evaluateScript(Self.glue)
            guard let function = context.objectForKeyedSubscript("__wingcordHighlight"),
                  !function.isUndefined,
                  let namesJSON = context.objectForKeyedSubscript("__wingcordNames")?.call(withArguments: [])?.toString(),
                  let data = namesJSON.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String: String].self, from: data)
            else { return nil }
            self.context = context
            self.highlightFunction = function
            self.names = names
        }

        func canonicalName(_ language: String) -> String? {
            names[language.lowercased()]
        }

        func highlight(_ code: String, language: String) -> [Token]? {
            guard let value = highlightFunction.call(withArguments: [code, language]),
                  value.isString, let json = value.toString(),
                  let data = json.data(using: .utf8),
                  let rows = try? JSONDecoder().decode([Row].self, from: data)
            else { return nil }
            return rows.map { Token(location: $0.location, length: $0.length, scopes: $0.scopes) }
        }

        /// `[location, length, [scope…]]`.
        private struct Row: Decodable {
            var location: Int
            var length: Int
            var scopes: [String]

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                location = try container.decode(Int.self)
                length = try container.decode(Int.self)
                scopes = try container.decode([String].self)
            }
        }

        /// What this file adds to the context: the call Discord's wrapper
        /// makes (`ignoreIllegals` on), its two-thousand-tag ceiling, and the
        /// emitter's tree flattened — positions in UTF-16 units, as
        /// `NSString` counts them.
        private static let glue = """
        function __wingcordHighlight(code, language) {
          if (!hljs.getLanguage(language)) return null;
          var result = hljs.highlight(code, { language: language, ignoreIllegals: true });
          var value = result.value, tags = 0;
          for (var i = 0; i < value.length; i++) if (value.charCodeAt(i) === 60) tags++;
          if (tags > 2000) return null;
          var out = [], position = 0;
          function walk(node, scopes) {
            var children = node.children;
            for (var i = 0; i < children.length; i++) {
              var child = children[i];
              if (typeof child === "string") {
                if (child.length > 0 && scopes.length > 0) out.push([position, child.length, scopes]);
                position += child.length;
              } else {
                walk(child, child.scope ? scopes.concat([child.scope]) : scopes);
              }
            }
          }
          walk(result._emitter.rootNode, []);
          return JSON.stringify(out);
        }
        function __wingcordNames() {
          var names = {};
          hljs.listLanguages().forEach(function (name) {
            name = name.toLowerCase();
            var language = hljs.getLanguage(name);
            if (!language) return;
            names[name] = name;
            (language.aliases || []).forEach(function (alias) { names[alias.toLowerCase()] = name; });
          });
          return JSON.stringify(names);
        }
        """
    }
}

nonisolated private extension Character {
    /// JavaScript's `\s`, which Discord's guards are written in.
    var isJavaScriptWhitespace: Bool {
        unicodeScalars.allSatisfy(\.isJavaScriptWhitespace)
    }
}

nonisolated private extension Unicode.Scalar {
    var isJavaScriptWhitespace: Bool {
        switch value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }
}

// MARK: - Colours

/// Which of Discord's `--text-code-*` a run of highlight.js scopes is drawn in
/// (`hljs-classes.css`, and the cascade over it: the innermost scope with a
/// rule wins its colour; bold, italic and the link's underline are inherited
/// from any scope around it).
nonisolated struct CodeTokenStyle: Equatable, Sendable {
    enum Ink: Equatable, Sendable {
        case keyword, type, title, variable, attribute, decorator, property, number
        case `operator`, string, regexp, builtin, comment, tag, section, bullet, link
        case addition, deletion
        /// `--text-code` — `subst`, `emphasis`, `strong` reset to it.
        case text
    }

    var ink: Ink?
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    /// `addition` / `deletion` lay their tint under the line.
    var ground: Ink?

    init(ink: Ink? = nil, isBold: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false, ground: Ink? = nil) {
        self.ink = ink
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.ground = ground
    }

    /// The style of text inside `scopes`, outermost first. A scope is
    /// highlight.js's own name — `title.class`, `variable.language`, `meta` —
    /// whose CSS classes are `hljs-title class_` and so on.
    static func resolve(_ scopes: [String]) -> CodeTokenStyle {
        var style = CodeTokenStyle()
        for scope in scopes {
            let base = scope.split(separator: ".", maxSplits: 1).first.map(String.init) ?? scope
            switch base {
            case "section": style.isBold = true
            case "strong": style.isBold = true
            case "emphasis": style.isItalic = true
            case "link": style.isUnderlined = true
            default: break
            }
            if let ink = ink(scope: scope, base: base) { style.ink = ink }
            if base == "addition" { style.ground = .addition }
            if base == "deletion" { style.ground = .deletion }
        }
        return style
    }

    private static func ink(scope: String, base: String) -> Ink? {
        // `.hljs-variable.language_` is a keyword, not a variable.
        if scope == "variable.language" { return .keyword }
        switch base {
        case "doctag", "keyword", "template-tag", "template-variable": return .keyword
        case "type", "built_in": return .type
        case "title": return .title
        case "literal", "params", "selector-attr", "selector-class", "selector-id", "variable": return .variable
        case "attr", "attribute": return .attribute
        case "meta": return .decorator
        case "property": return .property
        case "number": return .number
        case "operator": return .operator
        case "string": return .string
        case "regexp": return .regexp
        case "symbol": return .builtin
        case "code", "comment", "formula": return .comment
        case "name", "quote", "selector-pseudo", "selector-tag": return .tag
        case "subst", "emphasis", "strong": return .text
        case "section": return .section
        case "bullet": return .bullet
        case "link": return .link
        case "addition": return .addition
        case "deletion": return .deletion
        default: return nil
        }
    }
}

extension CodePalette {
    nonisolated func color(for ink: CodeTokenStyle.Ink) -> NSColor {
        switch ink {
        case .keyword: keyword
        case .type: type
        case .title: title
        case .variable: variable
        case .attribute: attribute
        case .decorator: decorator
        case .property: property
        case .number: number
        case .operator: self.operator
        case .string: string
        case .regexp: regexp
        case .builtin: builtin
        case .comment: comment
        case .tag: tag
        case .section: section
        case .bullet: bullet
        case .link: link
        case .addition: addition
        case .deletion: deletion
        case .text: text
        }
    }

    nonisolated func ground(for ink: CodeTokenStyle.Ink) -> NSColor? {
        switch ink {
        case .addition: additionGround
        case .deletion: deletionGround
        default: nil
        }
    }
}

extension NSMutableAttributedString {
    /// Lays highlight.js's tokens over code already set in `font`: each run in
    /// its colour, the bold, italic and underlined ones in their face, a diff's
    /// lines on their tint. Offsets past the text are ignored.
    nonisolated func applyHighlighting(_ tokens: [CodeHighlighter.Token], palette: CodePalette, font: NSFont) {
        let length = self.length
        var faces: [Int: NSFont] = [:]
        func face(bold: Bool, italic: Bool) -> NSFont {
            let key = (bold ? 1 : 0) | (italic ? 2 : 0)
            if let known = faces[key] { return known }
            var made = bold ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold) : font
            if italic {
                let traits = made.fontDescriptor.symbolicTraits.union(.italic)
                made = NSFont(descriptor: made.fontDescriptor.withSymbolicTraits(traits), size: made.pointSize) ?? made
            }
            faces[key] = made
            return made
        }
        beginEditing()
        for token in tokens where token.location >= 0 && token.location + token.length <= length {
            let style = CodeTokenStyle.resolve(token.scopes)
            let range = token.range
            if let ink = style.ink {
                addAttribute(.foregroundColor, value: palette.color(for: ink), range: range)
            }
            if style.isBold || style.isItalic {
                addAttribute(.font, value: face(bold: style.isBold, italic: style.isItalic), range: range)
            }
            if style.isUnderlined {
                addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let ground = style.ground.flatMap(palette.ground(for:)) {
                addAttribute(.backgroundColor, value: ground, range: range)
            }
        }
        endEditing()
    }
}
