import Foundation
import Testing
import WingcordCore

/// Discord's loading placeholders — ThumbHash, decoded as its worker decodes
/// them. The hashes are the captures' own.
@Suite("Media placeholder")
struct MediaPlaceholderTests {

    /// The Lumen Club card's picture, 3200×1680 (`the components capture`).
    @Test("A wide picture's placeholder is 32 wide and keeps roughly its shape")
    func wide() throws {
        let pixels = try #require(MediaPlaceholder.decode(base64: "iAcGDIAYRWhwlnl5h3jXj3X5uA=="))
        #expect(pixels.width == 32)
        #expect(pixels.height < 32)
        #expect(abs(Double(pixels.width) / Double(pixels.height) - 3200.0 / 1680.0) < 0.6)
        #expect(pixels.rgba.count == pixels.width * pixels.height * 4)
        // Opaque, and not a flat field: something to look at.
        #expect(pixels.rgba.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })
        #expect(Set(pixels.rgba.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)).count > 1)
    }

    /// A GIF attachment's, 230×200 (`chat summaries.har`).
    @Test("An almost square picture's placeholder is almost square")
    func square() throws {
        let pixels = try #require(MediaPlaceholder.decode(base64: "UHgKDoJoqGd6h4llhgaZOcmHCUjsiFA="))
        #expect(max(pixels.width, pixels.height) == 32)
        #expect(min(pixels.width, pixels.height) >= 20)
    }

    @Test("Only a version this decodes is kept, and nothing is invented from a stub")
    func accepted() {
        #expect(MediaPlaceholder.accepted("abc", version: 1) == "abc")
        #expect(MediaPlaceholder.accepted("abc", version: nil) == "abc")
        #expect(MediaPlaceholder.accepted("abc", version: 2) == nil)
        #expect(MediaPlaceholder.accepted("", version: 1) == nil)
        #expect(MediaPlaceholder.decode(base64: "AAE=") == nil)
    }
}
