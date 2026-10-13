import AppKit
import SwiftUI

/// Discord's own icons, where an SF Symbol would be a stand-in for one that has
/// a shape of its own — and a plugin's, where the feature is the plugin's —
/// shipped as custom symbols in `Glyphs.xcassets`.
///
/// **Symbols, not shapes.** A symbol scales with the text beside it, takes the
/// same foreground style, sits on the baseline inside a `Text`, draws in a menu
/// and renders through `SymbolCache` into the transcript — everything the SF
/// Symbols around it do. A `Shape` in a frame does none of that, and every site
/// would need its own size.
///
/// **Converted from Discord's outlines, not traced.** The sources are the 24-unit
/// paths of `ThreadIcon` (`163328`), `ThreadLockIcon` (`425557`) and
/// `ThreadPlusIcon`, with every arc resolved to a cubic, placed on Apple's symbol
/// template: centred on the cap-height midline as SF Symbols are, at Discord's
/// own proportion to its `#` — 22.5 units of ink to 20 — measured against the SF
/// `number` that stands in for that `#` here, with its sidebearings. Checked by
/// rendering: the compiled symbols and the original paths overlap at 0.99.
nonisolated enum DiscordGlyph {
    /// A thread, public or announcement, and a forum post.
    static let thread = "discord.thread"
    /// Create Thread.
    static let newThread = "discord.thread.plus"
    /// Vencord's AnonymiseFileNames toggle on a staged file: Material's
    /// incognito, and the struck-through one the plugin draws mirrored.
    static let anonymous = "vencord.incognito"
    static let notAnonymous = "vencord.incognito.slash"

    /// Whether a symbol name is one of these rather than an SF Symbol.
    static func owns(_ name: String) -> Bool { name.hasPrefix("discord.") || name.hasPrefix("vencord.") }
}

extension Image {
    /// An SF Symbol, or one of Discord's glyphs where the name is one.
    ///
    /// **The one door for a symbol named at run time.** Names travel through
    /// presentations as strings — a channel's kind, a search result's mark —
    /// and `Image(systemName:)` draws *nothing* for a name it does not know, so a
    /// thread's glyph reaching one would vanish without a word.
    init(symbol name: String) {
        if DiscordGlyph.owns(name) {
            self.init(name, bundle: .module)
        } else {
            self.init(systemName: name)
        }
    }
}

extension NSImage {
    /// `Image(symbol:)` for what is drawn rather than composed — off the main
    /// actor, where `SymbolCache` rasterises.
    nonisolated static func symbol(named name: String) -> NSImage? {
        DiscordGlyph.owns(name)
            ? NSImage(symbolName: name, bundle: .module, variableValue: 0)
            : NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}
