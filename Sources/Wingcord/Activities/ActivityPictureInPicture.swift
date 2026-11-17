import SwiftUI

/// The running activity, small, over the rest of the window while the reader is
/// somewhere else (Discord's PiP: an activity whose channel isn't the one on
/// screen moves here, docs/ACTIVITIES-CALLS-PICKER.md decision 4).
///
/// **Dragged anywhere, settled in the nearest corner** with the throw's
/// momentum: the target is chosen from where the drag was *going*
/// (apple-design §6, deceleration 0.998), and the move is a critically damped
/// spring (damping 1, response 0.4, Apple's own PiP values). Under Reduce
/// Motion it fades into place instead. Interactive: the frame takes clicks and
/// keys as it does anywhere else.
struct ActivityPictureInPicture: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var corner: Corner = .bottomTrailing
    @State private var drag: CGSize = .zero

    private static let size = CGSize(width: 340, height: 191)
    private static let inset: CGFloat = 20

    enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let origin = position(of: corner, in: proxy.size)
                if model.activityHost == .pictureInPicture, let running = model.runningActivity,
                   let runtime = model.activityRuntime {
                    PictureInPictureCard(name: running.name, iconURL: running.iconURL, runtime: runtime, isReady: running.isReady)
                        .frame(width: Self.size.width, height: Self.size.height)
                        .offset(x: origin.x + drag.width, y: origin.y + drag.height)
                        .gesture(move(in: proxy.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else if let call = model.callPictureInPicture {
                    // **A call's stream or camera, in the same corner** (Alex,
                    // 2026-11-17): the activity has it first; one at a time.
                    CallPictureInPictureCard(content: call)
                        .frame(width: Self.size.width, height: Self.size.height)
                        .offset(x: origin.x + drag.width, y: origin.y + drag.height)
                        .gesture(move(in: proxy.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .id(call.userID)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 1), value: model.activityHost)
            .animation(.spring(response: 0.4, dampingFraction: 1), value: model.callPictureInPicture)
            .onChange(of: model.activityHost) { _, host in
                model.activityRuntime?.hostChanged(host)
            }
        }
    }

    private func move(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in drag = value.translation }
            .onEnded { value in settle(value, in: size) }
    }

    private func position(of corner: Corner, in size: CGSize) -> CGPoint {
        let maxX = size.width - Self.size.width - Self.inset
        let maxY = size.height - Self.size.height - Self.inset
        switch corner {
        case .topLeading: return CGPoint(x: Self.inset, y: Self.inset + 52)
        case .topTrailing: return CGPoint(x: maxX, y: Self.inset + 52)
        case .bottomLeading: return CGPoint(x: Self.inset, y: maxY)
        case .bottomTrailing: return CGPoint(x: maxX, y: maxY)
        }
    }

    /// The corner nearest where the throw would have come to rest.
    private func settle(_ value: DragGesture.Value, in size: CGSize) {
        let start = position(of: corner, in: size)
        let velocity = value.velocity
        func project(_ v: CGFloat) -> CGFloat { (v / 1000) * 0.998 / (1 - 0.998) }
        let resting = CGPoint(
            x: start.x + value.translation.width + project(velocity.width),
            y: start.y + value.translation.height + project(velocity.height)
        )
        let next = Corner.allCases.min { a, b in
            distance(position(of: a, in: size), resting) < distance(position(of: b, in: size), resting)
        } ?? corner
        let move: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 1)
        withAnimation(move) {
            corner = next
            drag = .zero
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

extension View {
    /// The running activity's picture in picture. Before the profiles, so a
    /// profile still comes up over it.
    func presentsActivityPictureInPicture() -> some View {
        modifier(ActivityPictureInPicture())
    }
}
