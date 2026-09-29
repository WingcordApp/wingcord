import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Discord's `IS_ANIMATED` mark, read off the wire.
///
/// Every fixture is a capture, verbatim: the mark is the server's own reading
/// of a file, so a hand-written one would only prove the decoder agrees with
/// its author.
@Suite("The animated mark")
struct AnimatedMarkDecodeTests {

    /// `chat summaries.har`: a GIF attachment, `flags: 32`.
    @Test("A GIF attachment carries the mark")
    func gifAttachment() throws {
        let json = #"""
        {"id": "1552282437163249240", "filename": "eKgLz349oH.gif", "size": 152293, "url": "https://cdn.discordapp.com/attachments/1087801778891175070/1552282437163249240/eKgLz349oH.gif?ex=6ab50b2d&is=6ab3b9ad&hm=03cf400f1483e988e468e0c6b02f731566786945dfe098967be46b67ef3435a9&", "proxy_url": "https://media.discordapp.net/attachments/1087801778891175070/1552282437163249240/eKgLz349oH.gif?ex=6ab50b2d&is=6ab3b9ad&hm=03cf400f1483e988e468e0c6b02f731566786945dfe098967be46b67ef3435a9&", "width": 230, "height": 200, "content_type": "image/gif", "flags": 32, "content_scan_version": 4, "placeholder": "UHgKDoJoqGd6h4llhgaZOcmHCUjsiFA=", "placeholder_version": 1}
        """#
        let attachment = try JSONDecoder().decode(AttachmentDTO.self, from: Data(json.utf8)).domain
        #expect(attachment.isMarkedAnimated)
        #expect(attachment.playsAsAnimated)
    }

    /// `inbox,fixed.har`: a PNG Discord stored as a WebP, with no `flags` at
    /// all — which is how every still in the captures arrives.
    @Test("A still attachment carries none, and a WebP of one does not move")
    func stillAttachment() throws {
        let json = #"""
        {"id": "1534699858401024898", "filename": "image.png", "size": 3702, "url": "https://cdn.discordapp.com/attachments/1507119769335577634/1534699858401024898/image.png?ex=6ab261df&is=6ab1105f&hm=986197dbc5dbbaa9b9484d9d7e8c3ccf460a69cdd62ea1285e02cbee6160b68e&", "proxy_url": "https://media.discordapp.net/attachments/1507119769335577634/1534699858401024898/image.png?ex=6ab261df&is=6ab1105f&hm=986197dbc5dbbaa9b9484d9d7e8c3ccf460a69cdd62ea1285e02cbee6160b68e&", "width": 75, "height": 66, "content_type": "image/webp", "original_content_type": "image/png", "content_scan_version": 4, "placeholder": "0bYNJogEWpuIeIeRiYp3SLiH+Ya/f/g=", "placeholder_version": 1}
        """#
        let attachment = try JSONDecoder().decode(AttachmentDTO.self, from: Data(json.utf8)).domain
        #expect(!attachment.isMarkedAnimated)
        #expect(!attachment.playsAsAnimated)
    }

    /// `chat summaries.har`: an animated sticker's unfurl, its picture marked.
    @Test("An embed's picture carries the mark")
    func embedPicture() throws {
        let json = #"""
        {"type": "image", "url": "https://media.discordapp.net/stickers/1551834605885137621.gif?size=160&name=tenna+dance&lossless=true", "thumbnail": {"url": "https://media.discordapp.net/stickers/1551834605885137621.gif?size=160&name=tenna+dance&lossless=true", "proxy_url": "https://images-ext-1.discordapp.net/external/3Xn1RXL3alD_laA7VX2IPvbP4b6Es5VAZlKcllOJVYE/%3Fsize%3D160%26name%3Dtenna%2Bdance%26lossless%3Dtrue/https/media.discordapp.net/stickers/1551834605885137621.gif", "width": 128, "height": 128, "content_type": "image/gif", "placeholder": "KjiGDQI1d5iNdIUKhpdwnHwGCHaHeHNqhw==", "placeholder_version": 1, "flags": 32}, "content_scan_version": 4}
        """#
        let embed = try JSONDecoder().decode(EmbedDTO.self, from: Data(json.utf8)).domain
        let thumbnail = try #require(embed.thumbnail)
        #expect(thumbnail.isMarkedAnimated)
        #expect(thumbnail.playsAsAnimated)
    }
}
