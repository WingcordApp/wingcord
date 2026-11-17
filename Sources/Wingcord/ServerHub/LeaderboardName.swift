import AppKit
import SwiftUI
import WingcordCore

/// A name on the leaderboard as Discord draws it there (`F.g` with
/// `displayNameStylesFont`): the face its owner chose, in their role colour,
/// without the effect — the board is a list, and a column of names all
/// shimmering at once never settles.
struct LeaderboardName: View {
    var row: LeaderboardCardModel.Row
    /// Discord's size for the place: 14 on the podium and in a row.
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold

    var body: some View {
        Text(row.name)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var font: Font {
        row.nameFont
            .flatMap { DisplayNameFontRegistry.font($0, size: size) }
            .map(Font.init)
            ?? .system(size: size, weight: weight)
    }

    private var color: AnyShapeStyle {
        if row.isHidden { return AnyShapeStyle(Ink.secondary) }
        return row.nameColor.map { AnyShapeStyle(Color(hex: $0)) } ?? AnyShapeStyle(Ink.primary)
    }
}
