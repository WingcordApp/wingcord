import SwiftUI

/// A pennant: rounded at the top, coming to a point at the foot, as Discord's
/// podium pillars are.
nonisolated struct PodiumPillarShape: InsettableShape {
    /// How far the point drops below the sides.
    var point: CGFloat
    var corner: CGFloat = 12
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let radius = min(corner, box.width / 4)
        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: box.minY + radius))
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY),
                    tangent2End: CGPoint(x: box.minX + radius, y: box.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY),
                    tangent2End: CGPoint(x: box.maxX, y: box.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - point))
        path.addLine(to: CGPoint(x: box.midX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY - point))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> PodiumPillarShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}
