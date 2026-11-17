import SwiftUI

/// A place on the podium, and everything Discord draws for it — measured from
/// its hub module (`tN`, `e$`, `eQ`) and its stylesheet (`podium_i8iX4X`),
/// value for value. CSS pixels are points here.
enum PodiumPlace: Int, CaseIterable {
    case first = 1
    case second = 2
    case third = 3

    /// `.columnFirst` is 120 × 188; `.columnSecond` and `.columnThird` 96 × 156.
    var columnSize: CGSize {
        self == .first ? CGSize(width: 120, height: 188) : CGSize(width: 96, height: 156)
    }

    /// The face: 72 scaled to 64 for the winner, 40 beside it.
    var avatarSide: CGFloat { self == .first ? 64 : 40 }

    /// The ring's box, relative to the face's top-left corner (`.rankRing`).
    var ringFrame: CGRect {
        switch self {
        case .first: CGRect(x: -2, y: -3, width: 68, height: 68)
        case .second: CGRect(x: -3, y: -4, width: 46, height: 46)
        case .third: CGRect(x: -2, y: -3, width: 44, height: 45)
        }
    }

    /// The medal's top, from the column's (`.medalBadge`: 112, or 20 from the
    /// winner's foot).
    var medalTop: CGFloat {
        self == .first ? columnSize.height - 20 - PodiumPlace.medalSide : 112
    }

    static let medalSide: CGFloat = 24
    /// `.podium`: `space-192 + space-40 - 2px`.
    static let podiumHeight: CGFloat = 230
    /// What it grows from, `(space-48 + 2px) × 3`.
    static let collapsedHeight: CGFloat = 150
    static let columnGap: CGFloat = 8
    /// `.background`: 685 wide, the podium's height, centred.
    static let backdropWidth: CGFloat = 685
    /// `.podiumStack`'s `--custom-podium-hold`: the top three stand as rows
    /// for half a second before the podium takes their place.
    static let hold: Double = 0.5
}
