import AppKit
import Foundation
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// Prose outside the transcript, and what a reader can do with it.
///
/// **The bugs these pin** (Alex, 2026-11-04): "i cant copy any bio text or interact
/// with spoilers". Every word was its own view, so a selection had nothing to run
/// across, and a spoiler was clear ink with nothing listening for a click. The view
/// is pressed directly here, because everything that went wrong was what happens
/// after the layout, which an offscreen render can't show.
@MainActor
@Suite("Prose you can use")
struct ProseCanvasTests {

    private func drawing(_ markdown: String, lineLimit: Int? = nil) -> ProseDrawing {
        let environment = EnvironmentValues()
        return ProseDrawing(
            markdown: markdown,
            pointSize: 13,
            primary: Color.white.resolve(in: environment),
            secondary: Color.gray.resolve(in: environment),
            tertiary: Color.gray.resolve(in: environment),
            accent: Color.blue.resolve(in: environment),
            isLight: false,
            emojiSide: 18,
            lineLimit: lineLimit,
            plays: false
        )
    }

    private func view(
        _ markdown: String,
        width: CGFloat = 300,
        lineLimit: Int? = nil,
        selectsText: Bool = true,
        actions: ProseCanvasView.Actions = .init()
    ) throws -> (view: ProseCanvasView, block: TimelineTextBlock) {
        let view = ProseCanvasView()
        view.configure(
            drawing: drawing(markdown, lineLimit: lineLimit),
            mentions: MentionContext(),
            actions: actions,
            selectsText: selectsText
        )
        view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        return (view, try #require(view.layoutForTesting()))
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    // MARK: Selecting

    @Test("A drag runs across words and styles, and copies them as written")
    func dragAcrossWords() throws {
        let (view, block) = try view("one **two** *three*")
        view.press(at: CGPoint(x: 0, y: 2), clicks: 1)
        view.drag(to: CGPoint(x: 300, y: block.size.height - 1))
        view.release(at: CGPoint(x: 300, y: block.size.height - 1))
        #expect(view.selectedText() == "one two three")
    }

    @Test("A drag runs across lines")
    func dragAcrossLines() throws {
        let (view, block) = try view("first line\nsecond line")
        view.press(at: CGPoint(x: 0, y: 2), clicks: 1)
        view.drag(to: CGPoint(x: 300, y: block.size.height - 1))
        view.release(at: CGPoint(x: 300, y: block.size.height - 1))
        #expect(view.selectedText() == "first line\nsecond line")
    }

    @Test("A custom emoji copies as its name")
    func emojiCopiesAsName() throws {
        let (view, _) = try view("hi <:meow:123456789010468812> there")
        view.press(at: .zero, clicks: 3)
        view.release(at: .zero)
        #expect(view.selectedText() == "hi :meow: there")
    }

    @Test("Two clicks take the word, three take the lot")
    func clicks() throws {
        let (view, block) = try view("alpha beta")
        let word = try #require(block.selectionRects(for: NSRange(location: 0, length: 5)).first)
        view.press(at: center(word), clicks: 2)
        view.release(at: center(word))
        #expect(view.selectedText() == "alpha")
        view.press(at: center(word), clicks: 3)
        view.release(at: center(word))
        #expect(view.selectedText() == "alpha beta")
    }

    @Test("A click with no drag leaves nothing selected")
    func clickSelectsNothing() throws {
        let (view, _) = try view("alpha beta")
        view.press(at: CGPoint(x: 4, y: 4), clicks: 1)
        view.release(at: CGPoint(x: 4, y: 4))
        #expect(view.selectedRange == nil)
        #expect(view.selectedText() == nil)
    }

    // MARK: Spoilers

    @Test("A press lifts a spoiler, and starts nothing else")
    func spoilerReveals() throws {
        let (view, block) = try view("see ||a secret|| now")
        let cover = try #require(block.spoilerRects.first)
        #expect(!view.isRevealed(cover.spoiler))
        view.press(at: center(cover.rect), clicks: 1)
        view.release(at: center(cover.rect))
        #expect(view.isRevealed(cover.spoiler))
        #expect(view.selectedRange == nil)
    }

    @Test("A spoiler that wraps is lifted by one press, not one per line")
    func wrappedSpoilerRevealsOnce() throws {
        let long = "||" + String(repeating: "word ", count: 30) + "||"
        let (view, block) = try view(long, width: 120)
        #expect(block.spoilerRects.count > 1)
        let first = try #require(block.spoilerRects.first)
        view.press(at: center(first.rect), clicks: 1)
        view.release(at: center(first.rect))
        for cover in block.spoilerRects { #expect(view.isRevealed(cover.spoiler)) }
    }

    @Test("Once it's lifted, a spoiler is ordinary words to select")
    func revealedSpoilerSelects() throws {
        let (view, block) = try view("||secret||")
        let cover = try #require(block.spoilerRects.first)
        view.press(at: center(cover.rect), clicks: 1)
        view.release(at: center(cover.rect))
        view.press(at: center(cover.rect), clicks: 2)
        view.release(at: center(cover.rect))
        #expect(view.selectedText() == "secret")
    }

    // MARK: Links and emoji

    @Test("A link goes on release, and a drag from it is a selection")
    func linkOnRelease() throws {
        var followed: [MessageText.LinkTarget] = []
        let actions = ProseCanvasView.Actions(follow: { target, _ in followed.append(target) })
        let (view, block) = try view("go to https://example.com now", actions: actions)
        let link = try #require(block.linkRects.first)

        view.press(at: center(link.rect), clicks: 1)
        #expect(followed.isEmpty)
        view.release(at: center(link.rect))
        #expect(followed == [.url("https://example.com")])

        view.press(at: center(link.rect), clicks: 1)
        view.drag(to: CGPoint(x: 0, y: center(link.rect).y))
        view.release(at: CGPoint(x: 0, y: center(link.rect).y))
        #expect(followed.count == 1)
        #expect(view.selectedRange != nil)
    }

    @Test("A press on an emoji asks about that emoji")
    func emojiPress() throws {
        var asked: [EmojiRef] = []
        var places: [CGRect] = []
        let actions = ProseCanvasView.Actions(emoji: { emoji, rect in
            asked.append(emoji)
            places.append(rect)
        })
        let (view, block) = try view("hi <:meow:123456789010468812>", actions: actions)
        let emoji = try #require(block.emojiRects.first)
        view.press(at: center(emoji.rect), clicks: 1)
        view.release(at: center(emoji.rect))
        #expect(asked.map(\.name) == ["meow"])
        // Where it is, so its card opens on it and not at the surface's edge.
        #expect(places == [emoji.rect])
    }

    @Test("With no opener a link takes no click")
    func inertLink() throws {
        let (view, block) = try view("go to https://example.com")
        let link = try #require(block.linkRects.first)
        let host = NSView(frame: view.frame)
        host.addSubview(view)
        view.press(at: center(link.rect), clicks: 1)
        view.release(at: center(link.rect))
        #expect(view.selectedRange == nil)
    }

    // MARK: Inside something pressable

    @Test("On a pressable card the words let the press through, and a link keeps it")
    func pressThrough() throws {
        let actions = ProseCanvasView.Actions(follow: { _, _ in })
        let (view, block) = try view(
            "plain words and https://example.com and ||hidden||",
            selectsText: false,
            actions: actions
        )
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        host.addSubview(view)
        let word = try #require(block.selectionRects(for: NSRange(location: 0, length: 5)).first)
        let link = try #require(block.linkRects.first)
        let cover = try #require(block.spoilerRects.first)
        // `hitTest` takes its point in the superview's space.
        func hit(_ point: CGPoint) -> NSView? { view.hitTest(view.convert(point, to: host)) }
        #expect(hit(center(word)) == nil)
        #expect(hit(center(link.rect)) === view)
        #expect(hit(center(cover.rect)) === view)
    }

    // MARK: Size

    @Test("A line limit is honoured, and says so")
    func lineLimit() throws {
        let long = String(repeating: "word ", count: 80)
        let (_, block) = try view(long, width: 200, lineLimit: 2)
        #expect(block.lineCount == 2)
        #expect(block.text.attributed.string.hasSuffix("\u{2026}"))
    }

    @Test("A line limit that isn't reached adds nothing")
    func lineLimitNotReached() throws {
        let (_, block) = try view("short", width: 200, lineLimit: 2)
        #expect(block.text.attributed.string == "short")
    }

    @Test("Something with no spaces to break at keeps the width it's given")
    func unbreakable() throws {
        for words in [
            "https://steamcommunity.com/tradeoffer/new/?partner=1249542580&token=aBcDeFgHaBcDeFgH",
            String(repeating: "\u{4EBA}\u{8A00}\u{53EF}\u{754F}", count: 20),
        ] {
            let (view, _) = try view(words, width: 200)
            let size = view.size(for: ProposedViewSize(width: 200, height: nil))
            #expect(size.width == 200)
            #expect(size.height > 20)
        }
    }

    @Test("Asked for its ideal, it's its own widest line")
    func idealSize() throws {
        let (view, _) = try view("short")
        let ideal = view.size(for: .unspecified)
        #expect(ideal.width > 0 && ideal.width < 100)
    }

    @Test("Both spellings of a text style resolve to its size")
    func fonts() {
        #expect(NSFont.resolved(.system(.caption)).pointSize == NSFont.preferredFont(forTextStyle: .caption1).pointSize)
        #expect(NSFont.resolved(.caption).pointSize == NSFont.preferredFont(forTextStyle: .caption1).pointSize)
        #expect(NSFont.resolved(.system(.subheadline)).pointSize == NSFont.preferredFont(forTextStyle: .subheadline).pointSize)
    }

    @Test("Words get the plates of the room they're in, not the theme's")
    func platesByRoom() {
        let ink = ThemeInk.current
        #expect(ink.plates(isLight: ink.isLight).quoteRule == ink.plates.quoteRule)
        #expect(ink.plates(isLight: !ink.isLight).quoteRule != ink.plates.quoteRule)
        #expect(ink.plates(isLight: !ink.isLight).spoilerHidden != ink.plates.spoilerHidden)
    }

    // MARK: Keeping it fixed

    /// The repository's own sources, so the rule below can't quietly stop applying.
    private func sources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Wingcord")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [(String, String)] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            found.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
        }
        #expect(found.count > 100)
        return found
    }

    @Test("A bio is never drawn as plain text, where it couldn't be used")
    func bioIsProse() throws {
        let plain = /Text\((verbatim:\s*)?([A-Za-z.]*\.)?bio\b/
        for source in try sources() {
            #expect(source.text.firstMatch(of: plain) == nil, "\(source.path) draws a bio with Text")
        }
    }

    @Test("Everything on a profile stays selectable by default")
    func profileRootSelects() throws {
        let ground = try #require(try sources().first { $0.path == "ProfileGround.swift" })
        #expect(ground.text.contains(".textSelection(.enabled)"))
    }
}
