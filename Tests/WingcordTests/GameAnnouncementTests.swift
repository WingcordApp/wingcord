import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The digest a game's announcement shelf carries.
///
/// **Every string below is the shape a real post arrives in.** A community
/// announcement is not prose with a link in it — it is a heading, a paragraph,
/// a role ping and two masked links whose targets are wrapped in `<>` to
/// suppress the embed, and the version this replaces printed all of that
/// verbatim on the card.
@Suite("Game announcements")
@MainActor
struct GameAnnouncementTests {

    @Test("A masked link becomes its label, not its markup")
    func maskedLink() {
        let source = "Watch Grand Theft Auto VI: An Extended Look. Now on Netflix "
            + "<@&1299097019163480074> [netflix.com/GTAVI](<https://netflix.com/GTAVI>)"
        let excerpt = AppModel.excerpt(source)
        #expect(excerpt == "Watch Grand Theft Auto VI: An Extended Look. Now on Netflix netflix.com/GTAVI")
    }

    /// **The one place this differs from `MarkdownDocument.plainText`.** That
    /// fold answers `@role`, which is right for an accessibility label and is a
    /// fake name on a card: the post comes from the game's own server and the
    /// reader is usually not in it, so nothing can resolve the id.
    @Test("A mention is dropped, and so is the space it left")
    func mentionsDropped() {
        let excerpt = AppModel.excerpt("Live now <@&1299097019163480074> <@123> <#456> @everyone")
        #expect(excerpt == "Live now")
    }

    /// A paragraph that was only a ping leaves no blank line behind it.
    @Test("A paragraph of nothing but pings does not become a gap")
    func emptyParagraph() {
        let excerpt = AppModel.excerpt("Patch notes are up.\n\n<@&99>\n\nSee you in game.")
        #expect(excerpt == "Patch notes are up.\nSee you in game.")
    }

    /// Headings and emphasis were the only two the old reduction handled, and
    /// they still have to work.
    @Test("A heading keeps its words and loses its marks")
    func headingsAndEmphasis() {
        let excerpt = AppModel.excerpt("## Map Tools Update\n**Bigger** and *better* and `faster`")
        #expect(excerpt == "Map Tools Update\nBigger and better and faster")
    }

    /// A bare URL is the words the author wrote, so it stays.
    @Test("An autolink survives as its address")
    func autoLink() {
        let excerpt = AppModel.excerpt("Details at https://rockstargames.com/VI")
        #expect(excerpt == "Details at https://rockstargames.com/VI")
    }

    /// The card is an excerpt, not a transcript: a custom emoji has no picture
    /// on this surface, and its shortcode is what a reader can still read.
    @Test("A custom emoji becomes its shortcode")
    func customEmoji() {
        let excerpt = AppModel.excerpt("Season two <:hype:123456789>")
        #expect(excerpt == "Season two :hype:")
    }
}
