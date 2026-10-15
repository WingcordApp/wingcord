import AppKit
import Foundation
import WingcordCore

/// Discord's code colours for the room the reader is in: the `--text-code-*`
/// tokens highlight.js's classes map to, and the sixteen `--ansi-*` an `ansi`
/// block's named colours are drawn in.
///
/// **Measured, not designed** — resolved to hex from Discord's own stylesheet
/// (web `94f77ed563542b5d`, `docs/research/2026-10-15/highlight/
/// code-and-ansi-palette.json`), so a block reads here in the colours it reads
/// in there. Two rooms, and each has a high-contrast set, which Discord shows
/// under its own high-contrast mode and this app under Increase Contrast.
/// Discord's midnight and darker sets are not used: every dark room here takes
/// the dark set, as the default dark theme does.
///
/// **Static colours, resolved once per style.** The room is part of
/// `MessageTextStyle`'s equality, so moving between rooms re-lays the rows that
/// baked these in — a theme change already does, and Increase Contrast does
/// because of this.
nonisolated struct CodePalette: @unchecked Sendable {
    enum Room: Hashable, Sendable {
        case dark, light, darkHighContrast, lightHighContrast

        init(isLight: Bool, highContrast: Bool) {
            switch (isLight, highContrast) {
            case (false, false): self = .dark
            case (true, false): self = .light
            case (false, true): self = .darkHighContrast
            case (true, true): self = .lightHighContrast
            }
        }
    }

    let room: Room
    let keyword: NSColor
    let type: NSColor
    let title: NSColor
    let variable: NSColor
    let attribute: NSColor
    let decorator: NSColor
    let property: NSColor
    let number: NSColor
    let `operator`: NSColor
    let string: NSColor
    let regexp: NSColor
    let builtin: NSColor
    let comment: NSColor
    let tag: NSColor
    let section: NSColor
    let bullet: NSColor
    let link: NSColor
    let addition: NSColor
    let deletion: NSColor
    /// `--text-code`: what a token with no colour of its own is drawn in, in
    /// a file preview. A message's code block keeps the transcript's ink.
    let text: NSColor
    /// `--background-code-addition` / `-deletion`, under a diff's lines.
    let additionGround: NSColor
    let deletionGround: NSColor
    /// The sixteen, in SGR order: black, red, green, yellow, blue, magenta,
    /// cyan, white, then the bright eight.
    let ansi: [NSColor]

    init(room: Room) {
        self.room = room
        let hex = Self.hex(for: room)
        func color(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha
            )
        }
        keyword = color(hex.keyword)
        type = color(hex.type)
        title = color(hex.title)
        variable = color(hex.variable)
        attribute = color(hex.attribute)
        decorator = color(hex.decorator)
        property = color(hex.property)
        number = color(hex.number)
        self.operator = color(hex.operator)
        string = color(hex.string)
        regexp = color(hex.regexp)
        builtin = color(hex.builtin)
        comment = color(hex.comment)
        tag = color(hex.tag)
        section = color(hex.section)
        bullet = color(hex.bullet)
        link = color(hex.link)
        addition = color(hex.addition)
        deletion = color(hex.deletion)
        text = color(hex.text)
        additionGround = color(hex.additionGround.0, alpha: hex.additionGround.1)
        deletionGround = color(hex.deletionGround.0, alpha: hex.deletionGround.1)
        ansi = hex.ansi.map { color($0) }
    }

    /// An `ansi` span's colour: one of the room's sixteen, a fixed entry of the
    /// 256 table, or the colour it spelled out. Nil leaves the block's own ink —
    /// which is also what an index past the table comes to, as in Discord.
    func color(for ansiColor: ANSIEscapes.Color) -> NSColor? {
        switch ansiColor {
        case .named(let index):
            return ansi.indices.contains(index) ? ansi[index] : nil
        case .table(let index):
            if ansi.indices.contains(index) { return ansi[index] }
            guard let rgb = ANSIEscapes.tableRGB(index) else { return nil }
            return NSColor(
                srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255, alpha: 1
            )
        case .rgb(let red, let green, let blue):
            return NSColor(
                srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1
            )
        }
    }

    // MARK: The values

    private struct Hex {
        var keyword: UInt32
        var type: UInt32
        var title: UInt32
        var variable: UInt32
        var attribute: UInt32
        var decorator: UInt32
        var property: UInt32
        var number: UInt32
        var `operator`: UInt32
        var string: UInt32
        var regexp: UInt32
        var builtin: UInt32
        var comment: UInt32
        var tag: UInt32
        var section: UInt32
        var bullet: UInt32
        var link: UInt32
        var addition: UInt32
        var deletion: UInt32
        var text: UInt32
        var additionGround: (UInt32, CGFloat)
        var deletionGround: (UInt32, CGFloat)
        var ansi: [UInt32]
    }

    private static func hex(for room: Room) -> Hex {
        switch room {
        case .dark:
            Hex(
                keyword: 0xFFBDB9,
                type: 0xFFB6ED,
                title: 0xBCCAFF,
                variable: 0xFFFFFF,
                attribute: 0xABCFFF,
                decorator: 0xFFC252,
                property: 0x8EDAE1,
                number: 0xFCC0A1,
                operator: 0xFFCFCD,
                string: 0x96DDA9,
                regexp: 0x96DDA9,
                builtin: 0xFFC252,
                comment: 0xB3B3B9,
                tag: 0xFFB6ED,
                section: 0xFFBDB9,
                bullet: 0xABCFFF,
                link: 0xABCFFF,
                addition: 0x99E0AD,
                deletion: 0xFFBDB9,
                text: 0xFFFFFF,
                additionGround: (0x008545, 0.122),
                deletionGround: (0xD22D39, 0.122),
                ansi: [0x000000, 0xEC6361, 0x45A366, 0xCE8100, 0x4591EC, 0xF549C9, 0x049FAA, 0xB6B7BC, 0x70717A, 0xFF938E, 0x21BB63, 0xE79418, 0xA0A9FA, 0xFD99E9, 0x5FBFC8, 0xFFFFFF]
            )
        case .light:
            Hex(
                keyword: 0xA9232E,
                type: 0x9B277E,
                title: 0x404EB1,
                variable: 0x36373E,
                attribute: 0x0158AB,
                decorator: 0x884800,
                property: 0x00636E,
                number: 0x963B03,
                operator: 0x971D28,
                string: 0x006734,
                regexp: 0x006734,
                builtin: 0x884800,
                comment: 0x696A73,
                tag: 0x9B277E,
                section: 0xA9232E,
                bullet: 0x0158AB,
                link: 0x0158AB,
                addition: 0x005F30,
                deletion: 0x9E1F2A,
                text: 0x36373E,
                additionGround: (0x008545, 0.122),
                deletionGround: (0xD22D39, 0.122),
                ansi: [0x000000, 0xE75858, 0x399B5D, 0xC07600, 0x3789EA, 0xE444BB, 0x0098A3, 0xB6B7BC, 0x70717A, 0xCA2B37, 0x108E4D, 0xDB6E00, 0x5865F2, 0xB3269C, 0x007782, 0xFFFFFF]
            )
        case .darkHighContrast:
            Hex(
                keyword: 0xFFDEDD,
                type: 0xFFD7F4,
                title: 0xE5EFFF,
                variable: 0xFFFFFF,
                attribute: 0xE5EFFF,
                decorator: 0xFFE7CF,
                property: 0xC2F7FD,
                number: 0xFFE3D9,
                operator: 0xFFDEDD,
                string: 0xC1FCD1,
                regexp: 0xC1FCD1,
                builtin: 0xFFE7CF,
                comment: 0xC9CACE,
                tag: 0xFFD7F4,
                section: 0xFFDEDD,
                bullet: 0xE5EFFF,
                link: 0xE5EFFF,
                addition: 0xC5FFD5,
                deletion: 0xFFDEDD,
                text: 0xFFFFFF,
                additionGround: (0x008545, 0.122),
                deletionGround: (0xD22D39, 0.122),
                ansi: [0x000000, 0xF77B77, 0x5BB277, 0xE09000, 0x66A5F3, 0xFF66D8, 0x41B0BA, 0xB6B7BC, 0x70717A, 0xFF938E, 0x21BB63, 0xE79418, 0xA0A9FA, 0xFD99E9, 0x5FBFC8, 0xFFFFFF]
            )
        case .lightHighContrast:
            Hex(
                keyword: 0x7A111E,
                type: 0x6F1258,
                title: 0x003D7A,
                variable: 0x2F3035,
                attribute: 0x003D7A,
                decorator: 0x672D00,
                property: 0x00444E,
                number: 0x6D2400,
                operator: 0x7A111E,
                string: 0x00461F,
                regexp: 0x00461F,
                builtin: 0x672D00,
                comment: 0x52535D,
                tag: 0x6F1258,
                section: 0x7A111E,
                bullet: 0x003D7A,
                link: 0x003D7A,
                addition: 0x003F1B,
                deletion: 0x6C0B19,
                text: 0x2F3035,
                additionGround: (0x008545, 0.122),
                deletionGround: (0xD22D39, 0.122),
                ansi: [0x000000, 0xD22D39, 0x008043, 0xA56100, 0x006FD9, 0xC1389D, 0x007C87, 0xB6B7BC, 0x70717A, 0xCA2B37, 0x108E4D, 0xDB6E00, 0x5865F2, 0xB3269C, 0x007782, 0xFFFFFF]
            )
        }
    }
}
