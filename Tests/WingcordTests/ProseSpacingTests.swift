import AppKit
import Foundation
import SwiftUI
import Testing
import WingcordCore

@testable import Wingcord

/// A bio draws a space only where one was written.
///
/// The flow used to put a space between every two pieces of a line, so a car
/// typed as four custom emoji — one picture, written with nothing between the
/// pieces — came out as four pictures with three gaps (references 52 and 53).
/// What is pinned is which pieces touch.
@MainActor
struct ProseSpacingTests {

    private func emoji(_ name: String, _ id: UInt64) -> InlineNode {
        .customEmoji(EmojiRef(id: EmojiID(rawValue: id), name: name))
    }

    private func joins(_ nodes: [InlineNode]) -> [Bool] {
        ProseSegment.lines(of: nodes, style: .body, mentions: nil).flatMap { $0 }.map(\.joinsPrevious)
    }

    @Test("Custom emoji written back to back touch")
    func emojiPictureTouches() {
        #expect(joins([emoji("car1", 1), emoji("car2", 2), emoji("car3", 3), emoji("car4", 4)])
            == [false, true, true, true])
    }

    @Test("Words and an emoji after a space keep their spaces")
    func spacesStay() {
        #expect(joins([.text("Pura vida 🤙")]) == [false, false, false])
    }

    @Test("An emoji typed straight after a word touches it, inside one text run or across nodes")
    func noSpaceMeansTouching() {
        #expect(joins([.text("word😀")]) == [false, true])
        #expect(joins([.text("see"), emoji("wave", 9)]) == [false, true])
        #expect(joins([.text("see "), emoji("wave", 9)]) == [false, false])
    }

    @Test("The flow honours a zero gap and keeps its spacing everywhere else")
    func flowHonoursTheGap() {
        func width(touching: Bool) -> CGFloat {
            let flow = FlowLayout(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Color.red
                        .frame(width: 18, height: 18)
                        .layoutValue(key: FlowGap.self, value: touching && index > 0 ? 0 : nil)
                }
            }
            return NSHostingView(rootView: flow.fixedSize()).fittingSize.width
        }
        #expect(width(touching: true) == 72)
        #expect(width(touching: false) == 84)
    }

    @Test("A new line starts fresh")
    func lineBreakResets() {
        let lines = ProseSegment.lines(
            of: [emoji("a", 1), .lineBreak, emoji("b", 2), emoji("c", 3)],
            style: .body,
            mentions: nil
        )
        #expect(lines.map { $0.map(\.joinsPrevious) } == [[false], [false, true]])
    }
}
