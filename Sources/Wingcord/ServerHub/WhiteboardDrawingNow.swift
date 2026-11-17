import SwiftUI

/// "3 drawing now", with their faces: the board is busy, and joining it is
/// joining them.
struct WhiteboardDrawingNow: View {
    var faces: [WhiteboardCardModel.Face]
    var count: Int

    var body: some View {
        HStack(spacing: Spacing.base) {
            HStack(spacing: -6) {
                ForEach(faces) { face in
                    AvatarView(url: face.url, monogram: face.monogram, side: 22)
                        .overlay { Circle().strokeBorder(Palette.surface, lineWidth: 2) }
                }
            }
            Text(count == 1 ? "1 drawing now" : "\(count) drawing now")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(count == 1 ? "1 person drawing now" : "\(count) people drawing now"))
    }
}
