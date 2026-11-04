import SwiftUI
import WingcordCore

/// The buttons on the member row under the pointer: Join Voice where it applies,
/// Send Message, and More Options — Discord's `ty` (`763349`), in the place of the
/// row's picture (Alex's screenshot 45).
///
/// **Real glass over the drawn row, not squares painted into it**, as the message
/// bar is over the transcript: the canvas publishes the row's frame in the scroll
/// view's own space, and this sits on it.
struct MemberRowActionsOverlay: View {
    var hover: MemberRowHover?
    /// Whether the pointer is on the buttons: what keeps the row lit once it has
    /// left the row for them.
    @Binding var isPointerOnActions: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// Where this overlay starts, in the SwiftUI root's space. See
    /// `MessageActionBarOverlay.originInRoot`.
    @State private var originInRoot: CGPoint = .zero

    private static let trailing = MemberRowGeometry.horizontalMargin + MemberRowGeometry.contentInset
    private static let side = MemberRowGeometry.actionSide

    var body: some View {
        GeometryReader { proxy in
            if let hover {
                GlassEffectContainer(spacing: MemberRowGeometry.actionGap) {
                    HStack(spacing: MemberRowGeometry.actionGap) {
                        if let room = hover.joinableVoiceChannelID {
                            button("Join Voice", symbol: "speaker.wave.2.fill") { model.joinVoice(room) }
                        }
                        if !hover.isReader {
                            button("Send Message", symbol: "bubble.left.fill") {
                                model.messagePerson(hover.userID)
                            }
                        }
                        button("More Options", symbol: "ellipsis") {
                            model.openUserMenu(for: hover.userID, anchor: moreAnchor(of: hover, width: proxy.size.width))
                        }
                    }
                }
                .fixedSize()
                .onHover { isPointerOnActions = $0 }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, Self.trailing)
                .offset(y: hover.rowFrame.midY - Self.side / 2)
                .id(hover.userID)
                .transition(.materialize(from: .trailing, blurring: false))
            }
        }
        .animation(motion.hover, value: hover?.userID)
        .onGeometryChange(for: CGPoint.self) { proxy in
            proxy.frame(in: .global).origin
        } action: { origin in
            let resolved = CGPoint(
                x: origin.x - PresentationOrigin.value.x,
                y: origin.y - PresentationOrigin.value.y
            )
            guard resolved != originInRoot else { return }
            originInRoot = resolved
        }
    }

    private func button(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(InkColor.solid)
                .frame(width: Self.side, height: Self.side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    /// The menu hangs off the More button. **Solved, not measured**, as the message
    /// bar's anchors are: it's the last button, a fixed size from the trailing edge.
    private func moreAnchor(of hover: MemberRowHover, width: CGFloat) -> CGRect {
        CGRect(
            x: originInRoot.x + width - Self.trailing - Self.side,
            y: originInRoot.y + hover.rowFrame.midY - Self.side / 2,
            width: Self.side,
            height: Self.side
        )
    }
}

/// A room's Join, or Disconnect where the reader's in it — Discord's `no` (`763349`):
/// 24 points tall at the far end of the room's heading, green, and red for leaving.
struct MemberVoiceButtonsOverlay: View {
    var buttons: [MemberVoiceButton]

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        GeometryReader { _ in
            ForEach(buttons) { button in
                Button {
                    if button.isReaderIn { model.leaveVoice() } else { model.joinVoice(button.channelID) }
                } label: {
                    Text(button.isReaderIn ? "Disconnect" : "Join")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(button.isReaderIn ? Palette.destructive : Palette.presenceOnline).interactive(),
                    in: .capsule
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, MemberSectionGeometry.inset)
                .offset(y: button.frame.midY - 12)
                .transition(.opacity)
            }
        }
        .animation(motion.hover, value: buttons)
    }
}
