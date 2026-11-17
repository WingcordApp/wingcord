import Testing
@testable import WingcordCore

/// Discord's `@silent` rule (`677413`): the prefix, then a space or the end.
struct SilentMessageTests {

    @Test("@silent and a space sends the rest silently")
    func prefixed() {
        let parsed = SilentMessage.parse("@silent  good night")
        #expect(parsed.isSilent)
        #expect(parsed.content == "good night")
    }

    @Test("@silent alone is silent and empty")
    func alone() {
        let parsed = SilentMessage.parse("@silent")
        #expect(parsed.isSilent)
        #expect(parsed.content.isEmpty)
    }

    @Test("A word that only starts with it, or a mention later on, is not silent", arguments: [
        "@silently", "hello @silent", "@Silent hi",
    ])
    func notSilent(content: String) {
        let parsed = SilentMessage.parse(content)
        #expect(!parsed.isSilent)
        #expect(parsed.content == content)
    }
}
