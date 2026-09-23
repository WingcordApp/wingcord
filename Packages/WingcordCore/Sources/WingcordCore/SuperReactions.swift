import Foundation

// MARK: - The two halves of a reaction

/// Which half of a `Reaction` something is about.
///
/// The raw values are Discord's own `type`, which is what the reaction routes
/// take in their query and what `MESSAGE_REACTION_ADD` carries: `0` plain, `1`
/// super. (`2` is a poll vote, which arrives on its own events and is not a
/// reaction here.)
public enum ReactionKind: Int, Hashable, Sendable {
    case normal = 0
    case burst = 1
}

/// Which emoji a reaction is, the way `EmojiRef.isSameReaction(as:)` decides
/// it: a custom emoji by its id alone, a Unicode one by its sequence.
public enum ReactionEmojiKey: Hashable, Sendable {
    case custom(EmojiID)
    case unicode(String)
}

// MARK: - The tally

/// Discord's reducer for a message's reactions — `addReaction` and
/// `removeReaction` on its message record (module `383233`), ported.
///
/// **Every function answers nil when nothing changed**, and that is load
/// bearing rather than tidy: the gateway echoes the reader's own reaction back
/// after the optimistic write has already counted it, and a store that rebuilt
/// the message for an echo would repaint the row and re-key the layout cache
/// for a count that did not move.
public enum ReactionTally {

    /// Adds one reaction of `kind`.
    ///
    /// - Parameters:
    ///   - isMine: whether the reader is the one reacting. The reader counts
    ///     once per kind, so a second add of their own changes nothing.
    ///   - colors: the palette for a super reaction, used **only when the entry
    ///     has none yet** — Discord keeps the first palette an emoji arrived
    ///     with, so the reader's own client-side palette survives the echo
    ///     that carries the server's.
    ///   - isDirectMessage: a one-to-one conversation. There, somebody else's
    ///     add to a half that already has somebody else in it is a duplicate —
    ///     there *is* nobody else — and Discord drops it.
    public static func adding(
        _ emoji: EmojiRef,
        kind: ReactionKind,
        isMine: Bool,
        colors: [UInt32] = [],
        isDirectMessage: Bool = false,
        to reactions: [Reaction]
    ) -> [Reaction]? {
        guard let index = reactions.firstIndex(where: { $0.emoji.isSameReaction(as: emoji) })
        else {
            var added = reactions
            switch kind {
            case .normal:
                added.append(Reaction(emoji: emoji, count: 1, isMine: isMine))
            case .burst:
                added.append(Reaction(
                    emoji: emoji,
                    count: 0,
                    isMine: false,
                    burstCount: 1,
                    isMineBurst: isMine,
                    burstColors: Array(colors.prefix(3))
                ))
            }
            return added
        }

        var reaction = reactions[index]
        if isDirectMessage, !isMine {
            let others = reaction.count(of: kind) - (reaction.isMine(kind) ? 1 : 0)
            if others >= 1 { return nil }
        }
        switch kind {
        case .normal:
            if isMine, reaction.isMine { return nil }
            reaction.count += 1
            reaction.isMine = reaction.isMine || isMine
        case .burst:
            if isMine, reaction.isMineBurst { return nil }
            reaction.burstCount += 1
            reaction.isMineBurst = reaction.isMineBurst || isMine
            if reaction.burstColors.isEmpty { reaction.burstColors = Array(colors.prefix(3)) }
        }
        var updated = reactions
        updated[index] = reaction
        return updated
    }

    /// Removes one reaction of `kind`, and the whole entry once both halves
    /// are empty.
    ///
    /// The reader's own removal of a reaction they never made changes nothing,
    /// which is what makes a revert that crosses a gateway echo settle on the
    /// same count either way.
    public static func removing(
        _ emoji: EmojiRef,
        kind: ReactionKind,
        isMine: Bool,
        from reactions: [Reaction]
    ) -> [Reaction]? {
        guard let index = reactions.firstIndex(where: { $0.emoji.isSameReaction(as: emoji) })
        else { return nil }
        var reaction = reactions[index]
        switch kind {
        case .normal:
            if isMine, !reaction.isMine { return nil }
            // Clamped: a remove that arrives for a reaction the page was
            // fetched without must not leave a count below zero for the next
            // add to be measured from.
            reaction.count = max(0, reaction.count - 1)
            if isMine { reaction.isMine = false }
        case .burst:
            if isMine, !reaction.isMineBurst { return nil }
            reaction.burstCount = max(0, reaction.burstCount - 1)
            if isMine { reaction.isMineBurst = false }
        }
        var updated = reactions
        if reaction.count == 0, reaction.burstCount == 0 {
            updated.remove(at: index)
        } else {
            updated[index] = reaction
        }
        return updated
    }

    /// Takes one emoji off a message entirely — both halves, everybody's.
    /// `MESSAGE_REACTION_REMOVE_EMOJI`.
    public static func removingEmoji(_ emoji: EmojiRef, from reactions: [Reaction]) -> [Reaction]? {
        let kept = reactions.filter { !$0.emoji.isSameReaction(as: emoji) }
        return kept.count == reactions.count ? nil : kept
    }
}

// MARK: - The chip's colours

/// The colours a super reaction chip is drawn in — Discord's module `478840`,
/// ported, with the helpers it calls from `998304` and the parts of chroma.js
/// (`310784`) those reach.
///
/// **One colour decides everything.** Of the first three `burst_colors`, the
/// one with the highest saturation plus value wins; the chip's fill, its
/// border, its count and its glow are each that colour pushed through a
/// lightness shift and a contrast search against one of Discord's two
/// reference grounds.
///
/// **Checked against Discord's own output, not against a re-reading of its
/// code.** The derivation ran verbatim in Node over thirty-nine palettes —
/// greys, primaries, near-whites, the captured `x_shaq` set and thirty seeded
/// random ones — and `SuperReactionTests` pins every answer.
///
/// Two quirks are Discord's and kept:
///
///  - **The reference grounds are constants**, `#FFFFFF` for a light theme and
///    `#36393E` for a dark one — the old dark theme's chat — whatever the
///    reader's theme actually is.
///  - **A grey gets a much stronger fill.** Saturation under a tenth takes the
///    fill from 20 % to 50 % in a dark theme (10 % to 35 % in a light one),
///    because a tinted grey at 20 % is indistinguishable from a plain chip.
public struct SuperReactionPalette: Hashable, Sendable {

    /// One appearance's colours, packed `0xRRGGBB`.
    public struct Style: Hashable, Sendable {
        /// The chip's fill before `opacity`, and its border — opaque — when the
        /// reader is one of the people who super reacted.
        public var background: UInt32
        /// The count's ink and the glow's colour. Also what the effect's
        /// recolour is derived from.
        public var accent: UInt32
        /// The fill's alpha.
        public var opacity: Double
    }

    public let dark: Style
    public let light: Style

    /// Nil when there is no colour to derive from, which Discord draws as a
    /// plain chip.
    public init?(colors: [UInt32]) {
        guard let chosen = Self.mostVivid(colors) else { return nil }
        let base = RGB(chosen)
        let saturation = Self.discordHSL(base.r, base.b, base.g).saturation
        let isGrey = saturation < 0.1

        let lightFill = Self.contrastAdjusted(
            RGB(Self.shiftLightness(base, by: 0.6, lighten: true)),
            against: Self.white, ratio: 3
        )
        let darkFill = Self.contrastAdjusted(
            RGB(Self.shiftLightness(base, by: 0.6, lighten: false)),
            against: Self.darkGround, ratio: 5
        )
        let lightAccent = Self.contrastAdjusted(base, against: Self.white, ratio: 7)
        let darkAccent = Self.contrastAdjusted(base, against: Self.darkGround, ratio: 7)

        light = Style(
            background: Self.roundTrip(lightFill),
            accent: lightAccent.packed,
            opacity: isGrey ? 0.35 : 0.1
        )
        dark = Style(
            background: Self.roundTrip(darkFill),
            accent: darkAccent.packed,
            opacity: isGrey ? 0.5 : 0.2
        )
    }

    /// The style for a room.
    public func style(isLight: Bool) -> Style { isLight ? light : dark }

    // MARK: Picking the colour

    /// `h6`: the first three colours, sorted by HSV saturation plus value, most
    /// first — stably, so the earliest of a tie wins.
    ///
    /// Both halves are percentages rounded to two decimals *before* they are
    /// added, and the rounding is kept because it decides ties.
    static func mostVivid(_ colors: [UInt32]) -> UInt32? {
        var best: (color: UInt32, score: Double)?
        for color in colors.prefix(3) {
            let c = RGB(color)
            let r = c.r / 255, g = c.g / 255, b = c.b / 255
            let value = max(r, g, b)
            let delta = value - min(r, g, b)
            let saturation = delta == 0 ? 0 : delta / value
            let score = Self.twoDecimals(100 * saturation) + Self.twoDecimals(100 * value)
            if best == nil || score > best!.score { best = (color, score) }
        }
        return best?.color
    }

    private static func twoDecimals(_ value: Double) -> Double {
        (100 * value).rounded() / 100
    }

    // MARK: Discord's own conversions (module 998304)

    /// `u`: sRGB bytes to hue in degrees, saturation and lightness in 0...1.
    static func discordHSL(_ red: Double, _ green: Double, _ blue: Double)
        -> (hue: Double, saturation: Double, lightness: Double)
    {
        let r = red / 255, g = green / 255, b = blue / 255
        let high = max(r, g, b), low = min(r, g, b)
        let lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        let sector: Double
        if high == r {
            sector = (g - b) / delta + (g < b ? 6 : 0)
        } else if high == g {
            sector = (b - r) / delta + 2
        } else {
            sector = (r - g) / delta + 4
        }
        return (360 * (sector / 6), saturation, lightness)
    }

    /// `_`: back to bytes, rounded.
    static func discordRGB(hue: Double, saturation: Double, lightness: Double) -> RGB {
        let h = hue / 360
        guard saturation != 0 else {
            let v = (255 * lightness).rounded()
            return RGB(v, v, v)
        }
        func channel(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        return RGB(
            (255 * channel(p, q, h + 1.0 / 3)).rounded(),
            (255 * channel(p, q, h)).rounded(),
            (255 * channel(p, q, h - 1.0 / 3)).rounded()
        )
    }

    /// `fE`: the same hue and saturation, lightness moved by `amount` — to
    /// 0.9 if lightening would pass white, to 0.1 if darkening would pass
    /// black.
    static func shiftLightness(_ color: RGB, by amount: Double, lighten: Bool) -> UInt32 {
        let hsl = discordHSL(color.r, color.g, color.b)
        let lightness = lighten
            ? (hsl.lightness + amount > 1 ? 0.9 : hsl.lightness + amount)
            : (hsl.lightness - amount < 0 ? 0.1 : hsl.lightness - amount)
        return discordRGB(hue: hsl.hue, saturation: hsl.saturation, lightness: lightness).packed
    }

    /// `WN`: a chroma colour's rounded channels through Discord's own HSL and
    /// back. It moves nothing for most inputs; it is kept because for the few
    /// it does move, Discord's answer is the one that moved.
    static func roundTrip(_ color: RGB) -> UInt32 {
        let rounded = RGB(color.r.rounded(), color.g.rounded(), color.b.rounded())
        let hsl = discordHSL(rounded.r, rounded.g, rounded.b)
        return discordRGB(hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness).packed
    }

    // MARK: The contrast search (module 998304's `lZ`, over chroma.js)

    private static let white = RGB(255, 255, 255)
    /// The old dark theme's chat. See the note on the type.
    private static let darkGround = RGB(0x36, 0x39, 0x3E)

    /// Steps lightness by 0.05 — up against a dark ground, down against a
    /// light one — until the contrast reaches `ratio`, **at most ten times**.
    /// Ten steps is half the lightness range, so a dark colour against a dark
    /// ground stops short of the ratio; that is Discord's answer too, and it is
    /// why a dark emoji's count reads as a muted tint rather than as white.
    static func contrastAdjusted(_ foreground: RGB, against ground: RGB, ratio: Double) -> RGB {
        let groundLuminance = luminance(ground)
        let isDarkGround = 0.5 >= groundLuminance
        var color = foreground
        var current = contrast(luminance(color), groundLuminance)
        var step = 0
        while step < 10, current < ratio {
            let lightness = chromaHSL(color).lightness
            if isDarkGround {
                guard lightness < 0.95 else { break }
                color = settingLightness(color, lightness + 0.05)
            } else {
                guard lightness > 0.05 else { break }
                color = settingLightness(color, lightness - 0.05)
            }
            current = contrast(luminance(color), groundLuminance)
            step += 1
        }
        return color
    }

    /// chroma.js's `rgb2hsl`. Hue is NaN for a grey, exactly as there.
    static func chromaHSL(_ color: RGB) -> (hue: Double, saturation: Double, lightness: Double) {
        let r = color.r / 255, g = color.g / 255, b = color.b / 255
        let low = min(r, g, b), high = max(r, g, b)
        let lightness = (high + low) / 2
        let saturation: Double
        if high == low {
            saturation = 0
        } else {
            saturation = lightness < 0.5
                ? (high - low) / (high + low)
                : (high - low) / (2 - high - low)
        }
        var hue = Double.nan
        if r == high {
            hue = (g - b) / (high - low)
        } else if g == high {
            hue = 2 + (b - r) / (high - low)
        } else if b == high {
            hue = 4 + (r - g) / (high - low)
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    /// chroma.js's `set('hsl.l', …)`: through its `hsl2rgb`, which rounds
    /// every channel **except a grey's**, left at `255 × l` — then clipped.
    static func settingLightness(_ color: RGB, _ lightness: Double) -> RGB {
        let hsl = chromaHSL(color)
        let s = hsl.saturation, l = lightness
        guard s != 0 else {
            let v = min(255, max(0, 255 * l))
            return RGB(v, v, v)
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let h = hsl.hue / 360
        func channel(_ offset: Double) -> Double {
            var t = h + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let value: Double
            if 6 * t < 1 {
                value = p + (q - p) * 6 * t
            } else if 2 * t < 1 {
                value = q
            } else if 3 * t < 2 {
                value = p + (q - p) * (2.0 / 3 - t) * 6
            } else {
                value = p
            }
            return min(255, max(0, (255 * value).rounded()))
        }
        return RGB(channel(1.0 / 3), channel(0), channel(-1.0 / 3))
    }

    /// chroma.js's `luminance()`: WCAG 2.0's, with its 0.03928 knee rather
    /// than sRGB's 0.04045. The difference moves no answer here, and the
    /// constant is kept because it is Discord's.
    static func luminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05)
    }

    /// Three channels in 0...255. **Fractional on purpose**: chroma.js keeps a
    /// grey's channels unrounded between steps, and rounding them early moves
    /// the next step's luminance.
    struct RGB: Hashable {
        var r: Double
        var g: Double
        var b: Double

        init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(_ packed: UInt32) {
            r = Double(packed >> 16 & 0xFF)
            g = Double(packed >> 8 & 0xFF)
            b = Double(packed & 0xFF)
        }

        /// chroma.js's `hex()`: each channel rounded, then packed.
        var packed: UInt32 {
            func byte(_ value: Double) -> UInt32 { UInt32(min(255, max(0, value.rounded()))) }
            return byte(r) << 16 | byte(g) << 8 | byte(b)
        }
    }
}

// MARK: - The effect

/// Which of Discord's eighteen super reaction effects plays for a reaction, and
/// how its artwork is fitted to the emoji and the chip's colour.
///
/// **Chosen by hash, so everybody sees the same one.** Module `299072` picks
/// with a string hash of the channel, the message and the emoji's name — no
/// randomness and nothing per reader — so a given super reaction always plays
/// the same effect, for every client. Captured: the `x_shaq` reaction in
/// `lottiesuperreaction.har` hashes to index 8, and hovering it loaded exactly
/// the chunk that holds index 8, StarBlast.
public enum SuperReactionEffect {

    /// Discord's loader table, **in its order** — the order is the answer, since
    /// the hash indexes it. Each name is the file this app bundles.
    public static let names: [String] = [
        "BlastOff", "Arcade", "BlackHoles", "Crystal", "Fireworks", "Fusion",
        "Pop", "PowerUp", "StarBlast", "Bubbles", "Slime", "Portal",
        "Anime", "Puzzle", "Spotlight", "Tube", "UFO", "Whirlwind",
    ]

    /// The effect's box, as a multiple of the emoji it plays around — `YY`,
    /// 7.5, in module `60317`. Discord's chip emoji is 20 points and its box
    /// 150.
    public static let boxToEmoji = 7.5

    /// The asset every effect draws the emoji into: `image_0`, a 128-unit
    /// square in all eighteen.
    public static let imageSide = 128.0

    /// The index into `names`.
    public static func index(channelID: ChannelID, messageID: MessageID, emojiName: String) -> Int {
        let hash = javaScriptHash("\(channelID.rawValue)\(messageID.rawValue)\(emojiName)")
        return Int(hash % Int64(names.count))
    }

    /// Module `297494`'s `H`, with JavaScript's arithmetic.
    ///
    /// **Not a 32-bit hash, which is what it looks like.** `t << 5` truncates
    /// `t` to 32 bits, but `- t + code` is then done in doubles, so the running
    /// value leaves the 32-bit range and is only truncated again at the next
    /// shift. The captured case hashes to 6,927,264,602; a 32-bit port answers
    /// a different effect for most reactions. And `charCodeAt` walks UTF-16
    /// units, which is what an emoji name's surrogate pairs are hashed as.
    static func javaScriptHash(_ string: String) -> Int64 {
        var value: Int64 = 0
        for unit in string.utf16 {
            value = Int64(Int32(truncatingIfNeeded: value) &<< 5) - value + Int64(unit)
        }
        return abs(value)
    }

    /// The two colours the artwork is repainted in: `Q7(accent, 2)`, the same
    /// hue rotation `PaletteHarmony` already ports for a profile.
    public static func tints(for accent: UInt32) -> (UInt32, UInt32) {
        let partners = PaletteHarmony.partners(
            of: SIMD3(UInt8(accent >> 16 & 0xFF), UInt8(accent >> 8 & 0xFF), UInt8(accent & 0xFF)),
            count: 2
        )
        func pack(_ c: SIMD3<UInt8>) -> UInt32 { UInt32(c.x) << 16 | UInt32(c.y) << 8 | UInt32(c.z) }
        return (pack(partners[0]), pack(partners[1]))
    }

    /// The artwork with Discord's two placeholder colours replaced — module
    /// `297494`'s `v`, as a text substitution over the JSON exactly as there.
    ///
    /// **Every effect is authored in pure red and pure blue**, `[1,0,0,` and
    /// `[0,0,1,` wherever a colour is keyed, and Discord swaps them for the
    /// chip's own pair before the animation is parsed. Substituting text rather
    /// than walking a parsed tree is deliberate: it is what Discord does, so it
    /// recolours precisely what Discord recolours, including any array that is
    /// not strictly a colour.
    public static func recolored(_ json: Data, accent: UInt32) -> Data {
        let (first, second) = tints(for: accent)
        return json
            .replacing(Array("[1,0,0,".utf8), with: Array(component(first).utf8))
            .replacing(Array("[0,0,1,".utf8), with: Array(component(second).utf8))
    }

    /// Fits the emoji's slot to a picture that is not square — module `60317`'s
    /// `fz`, which rewrites the **first** `"w":128,"h":128` and the **first**
    /// `[64,64` anchor in the file, and nothing else.
    ///
    /// A square picture, whatever its size, changes nothing: the height it
    /// computes is 128 again.
    public static func fitted(_ json: Data, pictureWidth: Int, pictureHeight: Int) -> Data {
        guard pictureWidth > 0, pictureHeight > 0, pictureWidth != pictureHeight else { return json }
        let height = imageSide / Double(pictureWidth) * Double(pictureHeight)
        return json
            .replacingFirst(
                Array(#""w":128,"h":128"#.utf8),
                with: Array(#""w":128,"h":\#(height)"#.utf8)
            )
            .replacingFirst(
                Array(#""a":{"a":0,"k":[64,64"#.utf8),
                with: Array(#""a":{"a":0,"k":[64,\#(height / 2)"#.utf8)
            )
    }

    /// `[r,g,b,` with each channel as a fraction, the form a Lottie colour key
    /// takes.
    private static func component(_ color: UInt32) -> String {
        let r = Double(color >> 16 & 0xFF) / 255
        let g = Double(color >> 8 & 0xFF) / 255
        let b = Double(color & 0xFF) / 255
        return "[\(r),\(g),\(b),"
    }
}

private extension Data {
    /// The first occurrence of `pattern` replaced, or `self` when there is none.
    func replacingFirst(_ pattern: [UInt8], with replacement: [UInt8]) -> Data {
        guard let range = firstRange(of: pattern) else { return self }
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
