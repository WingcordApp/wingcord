import CoreGraphics
import Testing
import WingcordCore
@testable import Wingcord

/// Embeds, invites and app cards keep Discord's colours in every theme
/// (2026-11-16), and so do the buttons on them: brand, green, red and grey,
/// never the app's accent.
@Suite("Discord's card and buttons")
struct DiscordCardInkTests {

    private func hex(_ color: CGColor) -> UInt32 {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap {
            color.converted(to: $0, intent: .defaultIntent, options: nil)
        } ?? color
        let parts = (srgb.components ?? []).prefix(3).map { UInt32(($0 * 255).rounded()) }
        return parts.count == 3 ? parts[0] << 16 | parts[1] << 8 | parts[2] : 0
    }

    @Test("Each base's card and grey button are Discord's, as his screenshots measure")
    func tokens() {
        #expect(hex(DiscordCardInk(.dark).card) == 0x24_24_29)
        #expect(hex(DiscordCardInk(.dark).secondaryFill) == 0x32_32_37)
        #expect(hex(DiscordCardInk(.onyx).card) == 0x0A_0A_0C)
        #expect(hex(DiscordCardInk(.onyx).secondaryFill) == 0x1B_1B_1E)
        #expect(hex(DiscordCardInk(.ash).card) == 0x38_3B_40)
        #expect(hex(DiscordCardInk(.light).card) == 0xFF_FF_FF)
        #expect(hex(DiscordCardInk(.light).secondaryText) == 0x29_29_2E)
    }

    @Test("A grey button on a bubble is raised above a True Black one")
    func looseButtons() {
        #expect(hex(DiscordCardInk(.onyx).looseFill) == 0x32_32_37)
        #expect(hex(DiscordCardInk(.dark).looseFill) == hex(DiscordCardInk(.dark).secondaryFill))
    }

    @Test("Light rooms are light; True Black and every tinted room are Onyx; the rest go by their ground")
    func bases() {
        #expect(DiscordCardInk.base(for: .trueBlack) == .onyx)
        #expect(DiscordCardInk.base(for: .porcelain) == .light)
        #expect(DiscordCardInk.base(for: DiscordTheme.viceCity.colors) == .onyx)
        let dark = ThemeColors(canvas: 0x1A_1A_1E, surface: 0x20_20_24, surfaceRaised: 0x26_26_2A, accent: nil)
        #expect(DiscordCardInk.base(for: dark) == .dark)
        let ash = ThemeColors(canvas: 0x31_33_38, surface: 0x38_3A_40, surfaceRaised: 0x40_42_48, accent: nil)
        #expect(DiscordCardInk.base(for: ash) == .ash)
    }

    private func button(_ style: MessageComponent.Style, onCard: Bool = false) -> ComponentSlot {
        var slot = ComponentSlot(
            rect: .zero, label: "Go", emoji: nil, url: nil, customID: "go",
            isEnabled: true, style: style, isMenu: false
        )
        slot.isOnCard = onCard
        return slot
    }

    @Test("Each style is Discord's colour, lit under the pointer, whatever the accent")
    func buttonColours() {
        let card = DiscordCardInk(.onyx)
        func fill(_ style: MessageComponent.Style, lit: Bool = false, onCard: Bool = false) -> UInt32 {
            hex(TimelineRowPainter.buttonColors(for: button(style, onCard: onCard), isHovered: lit, card: card).fill)
        }
        #expect(fill(.primary) == 0x59_66_F2)
        #expect(fill(.primary, lit: true) == 0x45_52_BA)
        #expect(fill(.success) == 0x00_85_45)
        #expect(fill(.danger) == 0xD1_2E_38)
        #expect(fill(.secondary) == 0x32_32_37)
        #expect(fill(.link) == 0x32_32_37)
        #expect(fill(.secondary, onCard: true) == 0x1B_1B_1E)
        let text = TimelineRowPainter.buttonColors(for: button(.primary), isHovered: false, card: card).text
        #expect(hex(text) == 0xFF_FF_FF)
    }
}
