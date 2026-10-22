import Foundation
import WingcordCore

/// What the `--demo` reader owns, for the profile editor's flyouts.
///
/// **Only captured items** — the two nameplates, the decoration and the three
/// frames whose payloads this repository already holds — so every picture
/// comes off the public CDN and nothing asks Discord's API. No effect has been
/// captured, so the effects grid shows its empty line, which is a real state.
enum DemoCollectibles {
    static let owned: [OwnedCollectible] = [
        OwnedCollectible(
            skuID: "1417311919664005231", name: "Cosmic Storm", kind: .nameplate,
            asset: "nameplates/nameplate_bonanza/cosmic_storm/",
            label: "Purple and pink nebula clouds.", palette: "violet",
            acquiredAt: date(2025, 10)
        ),
        OwnedCollectible(
            skuID: rosesNameplateSKU, name: "Dark Roses", kind: .nameplate,
            asset: "nameplates/dark_roses/1526656194121568256/",
            label: "Blue roses with a butterfly.", palette: "cobalt",
            acquiredAt: date(2026, 4)
        ),
        OwnedCollectible(
            skuID: "1144059132517826601", name: "Smoke", kind: .avatarDecoration,
            asset: "a_10b9f886b513b77ccdd67c8784f1a496",
            label: "Smoke with Green Shining Border, Animated",
            acquiredAt: date(2025, 2), isNitroExclusive: true
        ),
        OwnedCollectible(
            skuID: "1515124557290410204", name: "Dark Roses (Blue)", kind: .profileFrame,
            asset: "", acquiredAt: date(2026, 5)
        ),
        OwnedCollectible(
            skuID: "1489396533643448380", name: "Kawaii Cat", kind: .profileFrame,
            asset: "", acquiredAt: date(2026, 3)
        ),
        OwnedCollectible(
            skuID: "1524193380492509345", name: "Fantasy Galaxy (White)", kind: .profileFrame,
            asset: "", acquiredAt: date(2026, 6)
        ),
    ]

    /// The sku the demo reader's own plate is worn under, so the flyout marks
    /// it as worn.
    static let rosesNameplateSKU = "1526656194121568256"

    private static func date(_ year: Int, _ month: Int) -> Date? {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: 12).date
    }
}
