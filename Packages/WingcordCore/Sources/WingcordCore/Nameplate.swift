import Foundation

/// The colour a nameplate names itself with.
///
/// **A nameplate's artwork covers only its trailing third.** Captured and
/// measured: Dark Roses is a 672x126 strip with alpha whose left two thirds are
/// fully transparent and whose roses sit along the bottom-right. Drawn alone on
/// a roster row, that reads as a picture floating beside somebody's name rather
/// than as a plate behind it — which is what the palette is for. It grounds the
/// row so the artwork and the name belong to one object.
///
/// **A `String`-backed enum over a raw string**, because the value reaches a
/// painter: a row that carried the wire's text would parse it per repaint, and
/// an unrecognised palette would be a colour decided inside a draw loop.
/// Unknown values decode to `.none`, which is a plate with artwork and no wash
/// rather than a plate that fails to draw.
///
/// The twelve names are Discord's. **The colours are this app's reading of
/// them, not sampled values** — no capture carries the palette table, and
/// `Tokens.swift` puts colour in the hands of user content, which is exactly
/// what a nameplate somebody bought is. Each is tuned to read true against the
/// near-black roster at the low opacity the wash is drawn with; a hue that only
/// works at full strength is the wrong value here.
public enum NameplatePalette: String, Hashable, Sendable, Codable, CaseIterable {
    case none
    case crimson
    case berry
    case sky
    case teal
    case forest
    case bubbleGum = "bubble_gum"
    case violet
    case cobalt
    case clover
    case lemon
    case white

    /// The wash, as a 24-bit RGB value. Nil for `.none`, which is a real state:
    /// a nameplate that asked for no colour must not be given one.
    ///
    /// A `UInt32` rather than a colour type for the same reason `Role` carries
    /// one — this module has no view layer, and the two surfaces that draw a
    /// plate resolve it themselves.
    public var colorValue: UInt32? {
        switch self {
        case .none: nil
        case .crimson: 0xD1_39_46
        case .berry: 0xB5_37_8E
        case .sky: 0x3D_A2_E8
        case .teal: 0x1E_A3_9C
        case .forest: 0x35_7F_47
        case .bubbleGum: 0xE8_74_AD
        case .violet: 0x84_57_E0
        case .cobalt: 0x33_5C_D6
        case .clover: 0x57_B2_4C
        case .lemon: 0xD9_B4_3F
        case .white: 0xD8_D8_E0
        }
    }
}

/// A nameplate, as an account wears it.
///
/// Two fields rather than a class: a nameplate is a path and a colour, and
/// boxing them would cost an allocation on a `UserDecoration` that already is
/// one. See `User` for why the cosmetics live behind a single reference.
public struct Nameplate: Hashable, Sendable, Codable {
    /// The CDN path prefix, **ending in a slash** — Discord sends
    /// `"nameplates/dark_roses/1526656194121568256/"` and the file name is
    /// appended to it. Stored as sent so nothing has to remember which half it
    /// is holding.
    public let asset: String
    public let palette: NameplatePalette
    /// What the plate shows, in Discord's words. The accessibility label.
    public let label: String?
    /// **The product this plate came from.** On the wire from the start and
    /// decoded past for as long: nothing that only *draws* a nameplate needs it,
    /// which is why it went unnoticed — but an editor does, because
    /// `nameplate_sku_id` is what a save sends and a picker has nothing to mark
    /// as current without it.
    public let skuID: String?

    /// Where the strip is.
    ///
    /// On the value rather than at each call site: `decoration?.nameplate?
    /// .artworkURL` flattens to one optional, where a builder reaching for
    /// `CDN.nameplate(asset:)` through two optionals produces a nested one and
    /// then a `?? nil` to unpick it.
    public var artworkURL: URL? { CDN.nameplate(asset: asset) }

    public init(
        asset: String,
        palette: NameplatePalette = .none,
        label: String? = nil,
        skuID: String? = nil
    ) {
        self.asset = asset
        self.palette = palette
        self.label = label
        self.skuID = skuID
    }
}
