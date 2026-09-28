import Testing
@testable import Wingcord

/// The shadows a framed popout casts, pinned to Discord's numbers.
///
/// **Ported, not chosen.** The offset, the blur and the three opacities are
/// read out of `315513.css` and `629972.css`, and the radius was measured
/// against Chrome's own `box-shadow`; a value rounded toward something nicer
/// would drift from the client these frames were authored for.
@MainActor
struct FrameShadowTests {

    @Test("Discord's geometry: twenty across and down, a thirty-pixel blur")
    func geometry() {
        #expect(FrameShadow.offset == 20)
        // Half the CSS blur — measured, see `FrameShadow.radius`.
        #expect(FrameShadow.radius == 15)
    }

    @Test("Each room takes Discord's own opacity")
    func opacityByRoom() {
        #expect(FrameShadow.opacity(in: .porcelain) == 0.13)
        #expect(FrameShadow.opacity(in: DiscordTheme.mintApple.colors) == 0.13)
        // True Black is this app's Midnight.
        #expect(FrameShadow.opacity(in: .trueBlack) == 0.6)
        // Every other dark room sits on Discord's dark base.
        #expect(FrameShadow.opacity(in: ThemePreset.graphite.colors) == 0.2)
        #expect(FrameShadow.opacity(in: DiscordTheme.midnightBlurple.colors) == 0.2)
    }
}
