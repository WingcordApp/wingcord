import Foundation
import Testing
@testable import WingcordCore

/// A custom typing indicator, and the sentence it changes.
struct TypingIndicatorStyleTests {
    private let heart = EmojiRef(name: "❤️")
    private let blob = EmojiRef(id: EmojiID(rawValue: 123_456_789_010_468_812), name: "", isAnimated: true)

    @Test("One typer says their word; more than one, the plain sentence")
    func sentences() {
        let yapping = TypingIndicatorStyle(emojis: [heart], animation: .wave, suggestion: .yapping)
        #expect(TypingSentence.make(names: ["Ana"], style: yapping) == "Ana is yapping…")
        #expect(TypingSentence.make(names: ["Ana"], style: nil) == "Ana is typing…")
        #expect(TypingSentence.make(names: ["Ana", "Ben"], style: yapping) == "Ana and Ben are typing…")
        #expect(TypingSentence.make(names: ["Ana", "Ben", "Cai"], style: nil) == "Ana, Ben and Cai are typing…")
        #expect(TypingSentence.make(names: ["A", "B", "C", "D"], style: nil) == "Several people are typing…")
        #expect(TypingSentence.make(names: [], style: yapping) == "")
    }

    @Test("Each name is a piece of its own, for the line to set in bold")
    func namePieces() {
        func named(_ names: [String]) -> [String] {
            TypingSentence.pieces(names: names, style: nil).filter { $0.isName }.map { $0.text }
        }
        #expect(named(["Ana"]) == ["Ana"])
        // A name that is also part of the words around it is still just the name.
        #expect(named(["an", "d"]) == ["an", "d"])
        #expect(named(["Ana", "Ben", "Cai"]) == ["Ana", "Ben", "Cai"])
        // Past three nobody is named, so nothing is bold.
        #expect(named(["A", "B", "C", "D"]).isEmpty)
        #expect(TypingSentence.pieces(names: [], style: nil).isEmpty)
    }

    @Test("A style is drawn for one typer only, and never a plain one")
    func drawnStyle() {
        let style = TypingIndicatorStyle(emojis: [heart, blob], animation: .pulse)
        #expect(TypingSentence.drawnStyle(typers: 1, style: style) == style)
        #expect(TypingSentence.drawnStyle(typers: 2, style: style) == nil)
        #expect(TypingSentence.drawnStyle(typers: 1, style: TypingIndicatorStyle()) == nil)
        #expect(TypingSentence.drawnStyle(typers: 1, style: nil) == nil)
    }

    @Test("Three emoji at most; unknown numbers read as plain")
    func limits() {
        let style = TypingIndicatorStyle(emojis: [heart, blob, heart, blob], animation: .ring)
        #expect(style.emojis.count == 3)
        let future = TypingIndicatorStyle(emojis: [], animationValue: 9, suggestionValue: 12)
        #expect(future.animation == .unspecified)
        #expect(future.suggestion == .unspecified)
        #expect(future.isPlain)
        #expect(TypingIndicatorStyle.Suggestion.daydreaming.verb == "daydreaming")
    }

    @Test("Surprise Me picks a motion and a word, and keeps the emoji")
    func surprise() {
        var generator = SystemRandomNumberGenerator()
        let style = TypingIndicatorStyle(emojis: [heart]).surprised(using: &generator)
        #expect(style.emojis == [heart])
        #expect(style.animation != .unspecified)
        #expect(style.suggestion != .unspecified)
    }
}
