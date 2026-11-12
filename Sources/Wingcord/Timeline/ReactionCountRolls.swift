import AppKit
import SwiftUI
import WingcordCore

/// One reaction chip, as something to animate: a message's, an emoji's, plain
/// or super.
nonisolated struct ReactionChipKey: Hashable, Sendable {
    var messageID: MessageID
    var emoji: ReactionEmojiKey
    var kind: ReactionKind
}

/// The pop a chip makes when it arrives or counts somebody in.
///
/// **Drawn by the canvas, as a scale about the chip's centre.** A bump rather
/// than a grow: it starts and ends at the chip's own size, so the first frame
/// is the chip where the layout put it and nothing has to be hidden while it
/// plays. Critically quick — a tenth of the chip, gone inside a third of a
/// second — because the chip is small and a reaction is not news.
nonisolated enum ReactionPop {
    /// How long a pop is worth redrawing for.
    static let duration = 0.36

    static func scale(at elapsed: Double) -> CGFloat {
        guard elapsed > 0, elapsed < duration else { return 1 }
        // A damped half-wave: up to about 1.10 at 60 ms, back through 1 at
        // 150 ms, a breath under it, and still.
        return 1 + 0.17 * CGFloat(exp(-9 * elapsed) * sin(2 * .pi * elapsed / 0.30))
    }
}

/// Counts that are changing, rolled by the system's own numeric transition.
///
/// **A layer over the one chip whose number moved, for as long as it moves.**
/// The transcript is a drawn canvas and a count is two digits of it; the native
/// roll (`contentTransition(.numericText)`) lives in SwiftUI's `Text`. Hosting
/// a `Text` on every chip to have it would cost the transcript its scrolling,
/// so the canvas keeps drawing every count and hands over exactly one — the
/// one that changed — for under half a second, then draws it again itself.
@MainActor
final class ReactionCountRolls {
    private struct Roll {
        var view: NSView
        var removal: Task<Void, Never>
    }

    private var rolls: [ReactionChipKey: Roll] = [:]

    /// How long a roll holds its chip's count. The transition is a 0.35-second
    /// spring; the margin is for its tail.
    private static let life: Duration = .milliseconds(480)

    var isEmpty: Bool { rolls.isEmpty }

    func contains(_ key: ReactionChipKey) -> Bool { rolls[key] != nil }

    /// Rolls `key`'s count from one number to the next, in `frame` of `host` —
    /// the chip's count box, in the canvas's own space.
    ///
    /// - Parameter finished: called when the roll has gone, so the canvas can
    ///   draw the number again.
    func roll(
        _ key: ReactionChipKey,
        from old: Int,
        to new: Int,
        frame: CGRect,
        font: NSFont,
        color: NSColor,
        in host: NSView,
        reduceMotion: Bool,
        finished: @escaping (ReactionChipKey) -> Void
    ) {
        remove(key)
        let view = PassthroughHostingView(rootView: ReactionCountRoll(
            old: old, new: new, font: font, color: color, reduceMotion: reduceMotion
        ))
        view.frame = frame
        host.addSubview(view)
        let removal = Task { [weak self] in
            try? await Task.sleep(for: Self.life)
            guard !Task.isCancelled else { return }
            self?.remove(key)
            finished(key)
        }
        rolls[key] = Roll(view: view, removal: removal)
    }

    /// Ends every roll: the rows moved, and a number left over a chip that is
    /// no longer under it is worse than a number that did not finish rolling.
    func removeAll() {
        for roll in rolls.values {
            roll.removal.cancel()
            roll.view.removeFromSuperview()
        }
        rolls.removeAll()
    }

    private func remove(_ key: ReactionChipKey) {
        guard let roll = rolls.removeValue(forKey: key) else { return }
        roll.removal.cancel()
        roll.view.removeFromSuperview()
    }
}

/// The number, rolling.
private struct ReactionCountRoll: View {
    var old: Int
    var new: Int
    var font: NSFont
    var color: NSColor
    var reduceMotion: Bool

    @State private var value: Int?

    var body: some View {
        let shown = value ?? old
        Text(verbatim: String(shown))
            .font(Font(font as CTFont))
            .foregroundStyle(Color(nsColor: color))
            // Up rolls up and down rolls down: the transition reads the value.
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(shown)))
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .task {
                withAnimation(.snappy(duration: 0.35)) { value = new }
            }
    }
}

/// A hosting view the pointer goes straight through: the chip under it is
/// still the thing being hovered and pressed.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
