import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Where a nameplate's artwork lands on a roster row.
///
/// The strip's real dimensions, measured on the asset Discord serves for Dark
/// Roses: **672x126 with alpha**, transparent across its leading two thirds,
/// with the roses along the bottom of the trailing third.
@Suite("Nameplate layout")
struct NameplateLayoutTests {

    private static let stripSize = CGSize(width: 672, height: 126)

    /// The plate on a two-line row in the roster at its ideal width.
    private func plate(rowHeight: CGFloat = MemberRowGeometry.rowHeight) -> CGRect {
        MemberRowGeometry.plateRect(in: CGRect(
            x: 0, y: 0, width: Proportions.memberColumnIdeal, height: rowHeight
        ))
    }

    @Test("The strip keeps its own proportions at any row height")
    func preservesAspect() {
        // The defect this exists for, and it only showed on half the roster.
        // A naive aspect-*fill* takes whichever fit is larger: for a tall plate
        // that is the height, which is correct; for a short one it is the width,
        // and since the drawn height is the plate's either way the strip gets
        // stretched vertically. Every rose an ellipse, on the shorter rows only.
        //
        // The roster now draws one height — see `MemberRowGeometry.rowHeight` —
        // but the rule is about the RECT, and the profile surfaces draw plates
        // at heights of their own. Checked across the range rather than at the
        // one number the roster happens to use.
        let sourceAspect = Self.stripSize.width / Self.stripSize.height
        for height in [32, MemberRowGeometry.rowHeight, 64] as [CGFloat] {
            let art = MemberRowGeometry.nameplateArtRect(
                in: plate(rowHeight: height), imagePixelSize: Self.stripSize
            )
            #expect(abs(art.width / art.height - sourceAspect) < 0.05)
        }
    }

    @Test("Fit to the plate's height, not to its width")
    func fitsToHeight() {
        // Measured on Discord's own roster: on a plate 540x87 device pixels,
        // the roses begin at x=345. Fitting to the width predicts 311 and
        // fitting to the height predicts 347 — a two-pixel answer against a
        // thirty-four-pixel one, which is what settled the rule.
        let reference = CGRect(x: 25, y: 8, width: 540, height: 87)
        let art = MemberRowGeometry.nameplateArtRect(
            in: reference, imagePixelSize: Self.stripSize
        )
        #expect(art.height == reference.height)
        #expect(abs(art.width - 464) <= 1)
        // Where the roses land: they begin 53% of the way across the strip.
        #expect(abs(art.minX + art.width * 0.53 - 345) <= 3)
    }

    @Test("It hangs off the trailing edge, and overflows the leading one")
    func anchorsToTheTrailingEdge() {
        // A nameplate is authored with its subject on the right and empty space
        // on the left, precisely so a name can sit over the empty half.
        // Anchoring the other way crops the subject out and leaves the busy
        // part under the text.
        let plate = plate()
        let art = MemberRowGeometry.nameplateArtRect(
            in: plate, imagePixelSize: Self.stripSize
        )
        #expect(art.maxX == plate.maxX)
        #expect(art.minY == plate.minY)
        #expect(art.maxY == plate.maxY)
        // Wider than the plate on a two-line row, so the clip takes the
        // leading end — which is the transparent end.
        #expect(art.minX < plate.minX)
    }

    @Test("A short plate leaves bare plate rather than stretching the strip")
    func shortRowLeavesRoomForTheWash() {
        // The strip is 5.33 wide and a short plate is wider in proportion, so
        // fitting to the height cannot cover it. That gap is exactly what the
        // palette's wash is for.
        let plate = plate(rowHeight: 32)
        let art = MemberRowGeometry.nameplateArtRect(
            in: plate, imagePixelSize: Self.stripSize
        )
        #expect(art.minX > plate.minX)
        #expect(art.width < plate.width)
    }

    @Test("Rows are the same height with a plate and without one")
    func plateChangesNoRowHeight() {
        // A nameplate is a paint-time addition and must stay one: rows that
        // grew for artwork would give a roster of mixed members a ragged edge.
        var bare = MemberEntry(
            userID: UserID(rawValue: 1), name: "a", monogram: "A",
            status: .online, isOnMobile: false, activityLine: nil, isBot: false
        )
        var plated = bare
        plated.nameplateURL = URL(string: "https://example.invalid/static.png")
        plated.nameplatePalette = .cobalt
        #expect(MemberRowGeometry.height(for: bare) == MemberRowGeometry.height(for: plated))

        bare.activityLine = ActivityStatusLine(glyph: .game, text: "Roblox")
        plated.activityLine = ActivityStatusLine(glyph: .game, text: "Roblox")
        #expect(MemberRowGeometry.height(for: bare) == MemberRowGeometry.height(for: plated))
    }

    @Test("A degenerate image cannot divide by zero")
    func survivesAZeroHeightImage() {
        let art = MemberRowGeometry.nameplateArtRect(
            in: plate(), imagePixelSize: CGSize(width: 672, height: 0)
        )
        #expect(art.width.isFinite)
    }

    @Test("Every palette but `none` resolves to a colour")
    func palettesResolve() {
        // `.none` is a real answer — a plate that asked for no wash must not be
        // given one by a fallback — and every other case must have a value, or
        // a plate somebody paid for draws as bare artwork.
        for palette in NameplatePalette.allCases where palette != .none {
            #expect(palette.colorValue != nil, "\(palette.rawValue) has no colour")
        }
        #expect(NameplatePalette.none.colorValue == nil)
    }

    @Test("The artwork URL appends the file name to a path that ends in a slash")
    func buildsTheAssetURL() {
        // Discord sends the asset with its trailing slash and the file name is
        // appended, not joined. Verified against the live CDN: `static.png`
        // answers 200 while `asset.png` and `static.webp` both 404.
        let nameplate = Nameplate(
            asset: "nameplates/dark_roses/1526656194121568256/", palette: .cobalt
        )
        #expect(
            nameplate.artworkURL?.absoluteString
                == "https://cdn.discordapp.com/assets/collectibles/nameplates/dark_roses/1526656194121568256/static.png"
        )
    }
}
