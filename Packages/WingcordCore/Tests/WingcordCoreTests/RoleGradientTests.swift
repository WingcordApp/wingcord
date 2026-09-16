import Testing
@testable import WingcordCore

/// The enhanced role style's stops.
///
/// **One definition, two renderers.** A profile's role chip is SwiftUI and the
/// member row is a painted canvas; they draw the same rule from different
/// layers, and two copies of the wrap is how they come to disagree about a
/// colour somebody chose.
@Suite("Role gradient")
struct RoleGradientTests {

    @Test("Two stops wrap back to the first, which is Discord's own rule")
    func twoStopsWrap() {
        let colors = RoleColors(primary: 0x4D_C1_FF, secondary: 0x00_82_F3)
        // `linear-gradient(to right, c1, c2, c1)` — the wrap is what makes a
        // repeating tile loop without a seam, and what makes the two ends of a
        // short name agree here.
        #expect(RoleColors.wrappedStops(colors) == [0x4D_C1_FF, 0x00_82_F3, 0x4D_C1_FF])
    }

    @Test("Three stops keep their order and wrap once")
    func threeStopsWrap() {
        let colors = RoleColors(primary: 0x11_11_11, secondary: 0x22_22_22, tertiary: 0x33_33_33)
        #expect(RoleColors.wrappedStops(colors)
            == [0x11_11_11, 0x22_22_22, 0x33_33_33, 0x11_11_11])
    }

    @Test("A flat role has no stops at all, rather than one repeated")
    func flatRoleHasNone() {
        // The painter branches on nil, so answering `[c, c]` here would put
        // every ordinary name through a gradient fill for no visible change.
        #expect(RoleColors.wrappedStops(RoleColors(primary: 0x4D_C1_FF)) == nil)
    }

    @Test("The colour and the stops come from ONE role")
    func oneRoleAnswersBoth() {
        let gradient = Role(
            id: RoleID(rawValue: 1), name: "Gradient",
            colorValue: 0x4D_C1_FF, position: 10,
            colors: RoleColors(primary: 0x4D_C1_FF, secondary: 0x00_82_F3)
        )
        let flat = Role(
            id: RoleID(rawValue: 2), name: "Flat",
            colorValue: 0xFF_00_00, position: 20
        )
        let roles = [gradient.id: gradient, flat.id: flat]
        let ids = [gradient.id, flat.id]

        // The higher role wins outright — and if the two were resolved
        // separately, this member would take the flat role's red with the
        // gradient role's blue stops painted through it.
        let top = RoleResolver.nameColorRole(of: ids, in: roles)
        #expect(top?.id == flat.id)
        #expect(top?.colors == nil)
        #expect(RoleResolver.nameColorValue(of: ids, in: roles) == 0xFF_00_00)
    }
}
