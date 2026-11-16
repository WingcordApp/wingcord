import SwiftUI

/// A whiteboard's dot grid, drawn once by `Canvas` rather than as hundreds of
/// views.
struct WhiteboardCanvasPattern: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.primary.opacity(0.14)))
                    x += step
                }
                y += step
            }
        }
        .accessibilityHidden(true)
    }
}
