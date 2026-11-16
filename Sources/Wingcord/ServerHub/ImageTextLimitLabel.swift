import SwiftUI

/// "42 / 500", turning to the warning colour in the last tenth.
struct ImageTextLimitLabel: View {
    var count: Int
    var limit: Int

    var body: some View {
        Text("\(count) / \(limit)")
            .font(.system(.caption))
            .monospacedDigit()
            .foregroundStyle(count >= limit * 9 / 10 ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
