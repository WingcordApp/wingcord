import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Telegram's sticky face in the transcript's bubbles (BETA2 §7): a run's face
/// sits on its last bubble, rides the readable bottom while that bubble is
/// below it, and never rises above the run's first bubble.
@MainActor
@Suite("Sticky faces")
struct StickyFacesTests {
    private static let me = UserID(rawValue: 1)
    private static let them = UserID(rawValue: 2)
    private static let other = UserID(rawValue: 3)

    private func run(top: CGFloat, natural: CGFloat, side: CGFloat = 28) -> StickyFaceRun {
        StickyFaceRun(
            headID: MessageID(rawValue: 1), tailID: MessageID(rawValue: 2), authorID: Self.them,
            isCrosspost: false, avatarURL: nil, monogram: "A", decorationURL: nil,
            natural: CGRect(x: 12, y: natural, width: side, height: side), top: top
        )
    }

    @Test("On its own place while that is in sight; riding the bottom while it is below; never above the first bubble")
    func placement() {
        let face = run(top: 100, natural: 900)
        // The last bubble in sight: the face is on it.
        #expect(face.y(readableBottom: 1_000) == 900)
        // The last bubble below the readable bottom: the face rides it.
        #expect(face.y(readableBottom: 600) == 572)
        // Scrolled so far that riding would lift it over the run: it stops at
        // the first bubble and scrolls away with it.
        #expect(face.y(readableBottom: 110) == 100)
        // A run shorter than its face can't ride at all.
        #expect(run(top: 120, natural: 110).y(readableBottom: 50) == 110)
    }

    private func layout(_ lines: [(UserID, String)]) -> (rows: [TimelineRow], offsets: [CGFloat]) {
        let messages = lines.enumerated().map { index, line in
            Message(
                id: MessageID(rawValue: UInt64(index + 1)),
                channelID: ChannelID(rawValue: 9),
                authorID: line.0,
                content: line.1
            )
        }
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let info = { (name: String) in
            TimelineLayoutEngine.AuthorInfo(
                name: name, colorValue: nil, avatarURL: nil, monogram: String(name.prefix(1)),
                decorationURL: nil, isBot: false
            )
        }
        let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: TimelineReducer.rows(messages: messages, failed: []),
                width: 800,
                style: MessageTextStyle.current(),
                mentions: MentionContext(selfIDs: [Self.me.rawValue]),
                channelName: "general",
                authors: [Self.me: info("Wren"), Self.them: info("Alder"), Self.other: info("Birch")],
                calendar: .current,
                settings: .comfortable,
                arrangement: .bubbles(namesAuthors: true)
            ),
            cache: &cache
        )
        var offsets: [CGFloat] = [0]
        for row in rows { offsets.append(offsets[offsets.count - 1] + row.height) }
        return (rows, offsets)
    }

    @Test("A run's face reaches from its last bubble back to its first, and the reader's own runs have none")
    func runsFromRows() throws {
        let laid = layout([
            (Self.them, "first"), (Self.them, "second, a bit longer"), (Self.them, "third"),
            (Self.me, "mine"),
            (Self.other, "somebody else"),
        ])
        let runs = StickyFaceRun.runs(in: laid.rows, offsets: laid.offsets)
        #expect(runs.count == 2)
        let first = try #require(runs.first)
        #expect(first.authorID == Self.them)
        #expect(first.headID == MessageID(rawValue: 1))
        #expect(first.tailID == MessageID(rawValue: 3))

        // The ceiling is the first bubble's top; the face's own place is on
        // the last row's foot.
        let rowIndex = { (id: UInt64) in
            laid.rows.firstIndex { $0.messageID == MessageID(rawValue: id) }!
        }
        guard case .message(let head) = laid.rows[rowIndex(1)].kind,
              case .message(let tail) = laid.rows[rowIndex(3)].kind
        else { Issue.record("not message rows"); return }
        let headBubble = try #require(head.bubbles?.bubble)
        let avatar = try #require(tail.avatarRect)
        #expect(first.top == laid.offsets[rowIndex(1)] + headBubble.rect.minY)
        #expect(first.natural == avatar.offsetBy(dx: 0, dy: laid.offsets[rowIndex(3)]))
        #expect(first.top < first.natural.minY)
        #expect(runs[1].authorID == Self.other)
    }

    @Test("Faces are laid where the viewport puts them, and answer for their person there")
    func layers() {
        let faces = StickyFaces(style: MessageTextStyle.current())
        let riding = run(top: 100, natural: 900)
        faces.update(runs: [riding])
        // The last bubble below the composer: the face rides above it.
        faces.place(visible: CGRect(x: 0, y: 0, width: 800, height: 700), readableBottom: 600, scale: 2)
        let placed = faces.face(at: CGPoint(x: 20, y: 590))
        #expect(placed?.run.authorID == Self.them)
        #expect(placed?.frame.minY == 572)
        // Its own place, out of sight, answers nothing: the face isn't there.
        #expect(faces.face(at: CGPoint(x: 20, y: 910)) == nil)
        #expect(faces.container.sublayers?.count == 1)
        // Scrolled to the run's top and past: nothing on screen holds it.
        faces.place(visible: CGRect(x: 0, y: 1_400, width: 800, height: 700), readableBottom: 2_000, scale: 2)
        #expect(faces.face(at: CGPoint(x: 20, y: 910)) == nil)
        #expect(faces.container.sublayers?.isEmpty != false)
    }
}
