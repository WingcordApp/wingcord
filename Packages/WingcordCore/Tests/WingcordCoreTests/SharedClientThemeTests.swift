import Foundation
import Testing
@testable import WingcordCore

/// A shared custom theme's own rules.
struct SharedClientThemeTests {

    @Test("Colours go out as six hex digits and come back with or without #")
    func hex() {
        #expect(SharedClientTheme.hex(0x58_65_F2) == "5865F2")
        #expect(SharedClientTheme.hex(0x00_00_0A) == "00000A")
        #expect(SharedClientTheme.color(fromHex: "#EB459E") == 0xEB_45_9E)
        #expect(SharedClientTheme.color(fromHex: "eb459e") == 0xEB_45_9E)
        #expect(SharedClientTheme.color(fromHex: "nope") == nil)
        #expect(SharedClientTheme.color(fromHex: "12345") == nil)
    }

    @Test("One colour spans the line as itself twice; the mix stays in range")
    func stops() {
        let one = SharedClientTheme(colors: [0x58_65_F2], gradientAngle: 90)
        #expect(one.gradientStops == [0x58_65_F2, 0x58_65_F2])
        #expect(one.baseMix == 74, "Discord's editor starts at 74")
        #expect(SharedClientTheme(colors: [1], gradientAngle: 0, baseMix: 140).baseMix == 100)
    }

    @Test("Only light is a light room; Discord keeps none without colours or a known room")
    func validity() {
        #expect(SharedClientTheme(colors: [1], gradientAngle: 0, baseTheme: 2).isLight)
        #expect(!SharedClientTheme(colors: [1], gradientAngle: 0, baseTheme: 4).isLight)
        #expect(!SharedClientTheme(colors: [], gradientAngle: 0).isValid)
        #expect(!SharedClientTheme(colors: [1], gradientAngle: 0, baseTheme: 9).isValid)
    }
}
