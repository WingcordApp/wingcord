import Testing
@testable import WingcordCore

/// The generated emoji table, and the four things every caller of it assumes.
///
/// A table is the one kind of code where a test is worth more than a reading:
/// it compiles whatever it contains, and a category that silently lost its
/// contents or a shortcode that quietly points at the wrong glyph looks exactly
/// like a correct one until somebody sends it.
@Suite("Unicode emoji")
struct UnicodeEmojiTests {

    @Test("Every category has contents, and the whole source survived the parse")
    func tableIsComplete() {
        var total = 0
        for category in UnicodeEmoji.Category.allCases {
            let items = UnicodeEmoji.items(in: category)
            #expect(!items.isEmpty, "\(category.title) is empty")
            total += items.count
        }
        // The count the generator reported. A parse that drops lines is
        // otherwise invisible — the picker just shows slightly less.
        #expect(total == 1906)
    }

    @Test("Shortcodes round-trip, with or without their colons")
    func shortcodesResolve() {
        #expect(UnicodeEmoji.glyph(for: "smile") == "😄")
        #expect(UnicodeEmoji.glyph(for: ":smile:") == "😄")
        #expect(UnicodeEmoji.glyph(for: "SMILE") == "😄")
        #expect(UnicodeEmoji.shortcode(for: "😄") == "smile")
        #expect(UnicodeEmoji.glyph(for: "not_an_emoji_name") == nil)
    }

    @Test("An alias resolves to the same glyph as its primary")
    func aliasesResolve() {
        let primary = UnicodeEmoji.glyph(for: "+1")
        #expect(primary == "👍")
        #expect(UnicodeEmoji.glyph(for: "thumbsup") == primary)
        // …but the name written back is the primary, not the alias.
        #expect(UnicodeEmoji.shortcode(for: "👍") == "+1")
    }

    @Test("Only the emoji that can wear a tone are marked as taking one")
    func toneCapabilityIsMarked() {
        let thumbsUp = UnicodeEmoji.items(in: .people).first { $0.name == "+1" }
        let burger = UnicodeEmoji.items(in: .food).first { $0.name == "hamburger" }
        #expect(thumbsUp?.takesSkinTone == true)
        #expect(burger?.takesSkinTone == false)
    }

    @Test("A tone is applied to every modifier base in the sequence")
    func toneAppliesThroughout() {
        #expect(UnicodeEmoji.applying(.medium, to: "👍") == "👍🏽")
        // Two people, two bases: toning only the first leaves a couple with
        // two different skin colours.
        #expect(UnicodeEmoji.applying(.light, to: "👨‍❤️‍👨") == "👨🏻‍❤️‍👨🏻")
        // Something with no base is returned untouched.
        #expect(UnicodeEmoji.applying(.dark, to: "🍔") == "🍔")
    }

    @Test("Switching tone replaces rather than accumulates")
    func toneIsReplaced() {
        let light = UnicodeEmoji.applying(.light, to: "👍")
        let dark = UnicodeEmoji.applying(.dark, to: light)
        #expect(dark == "👍🏿")
        #expect(UnicodeEmoji.applying(.default, to: dark) == "👍")
    }

    @Test("A toned glyph still answers with its shortcode")
    func tonedGlyphResolves() {
        let toned = UnicodeEmoji.applying(.mediumDark, to: "👍")
        #expect(UnicodeEmoji.shortcode(for: toned) == "+1")
    }

    /// The composer's autocomplete runs this on every keystroke.
    @Test("Prefix search is prefix-only, deduplicated, and bounded")
    func prefixSearch() {
        let hits = UnicodeEmoji.prefixed(by: "sob")
        #expect(hits.first?.glyph == "😭")

        let all = UnicodeEmoji.prefixed(by: "so", limit: 8)
        #expect(all.count == 8)
        #expect(all.allSatisfy { item in
            UnicodeEmoji.prefixed(by: item.name, limit: 1).first?.glyph == item.glyph
        })

        // One glyph, several names: the list must not spend two rows on it.
        let glyphs = UnicodeEmoji.prefixed(by: "thumbs", limit: 24).map(\.glyph)
        #expect(glyphs.count == Set(glyphs).count)

        #expect(UnicodeEmoji.prefixed(by: "").isEmpty)
        #expect(UnicodeEmoji.prefixed(by: "zzzzzz").isEmpty)
    }

    @Test("The picker's search finds names that merely contain the query")
    func substringSearch() {
        let hits = UnicodeEmoji.search("smile")
        let names = hits.map(\.name)
        #expect(names.contains("smile"))
        // `smile_cat` does not start with the query, so only the wider search
        // reaches it.
        #expect(names.contains { $0.contains("smile") && !$0.hasPrefix("smile") })
        #expect(hits.count == Set(hits.map(\.glyph)).count)
    }

    @Test("Every tone has a distinct swatch")
    func swatchesAreDistinct() {
        let swatches = UnicodeEmoji.SkinTone.allCases.map(\.swatch)
        #expect(swatches.count == Set(swatches).count)
        #expect(UnicodeEmoji.SkinTone.default.swatch == "✋")
    }
}
