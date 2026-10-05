import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Prose outside the transcript — a bio, a status, a server's description —
/// keeps the transcript's structure: a quote is a quote, a list hangs its
/// markers, and a timestamp is one run on its plate.
@Suite("Prose blocks")
@MainActor
struct ProseBlockTests {

    private func blocks(_ markdown: String) -> [ProseBlock] {
        ProseBlock.blocks(of: MarkdownParser().parse(markdown), mentions: nil)
    }

    @Test("A quote is a block of its own, not grey text")
    func quote() {
        let parsed = blocks("Primarily C# and C++\n> test")
        guard parsed.count == 2, case .quote(let children) = parsed[1].kind,
              case .lines(let lines)? = children.first?.kind
        else {
            Issue.record("expected a paragraph and a quote")
            return
        }
        guard case .word(let text, let style, _)? = lines.first?.first?.kind else {
            Issue.record("expected a word")
            return
        }
        #expect(text == "test")
        // The quote's words keep the body's role — and so its ink.
        #expect(style.role == .body)
        #expect(style.plate == nil)
    }

    @Test("A list carries its markers beside its items")
    func list() {
        let unordered = blocks("- one\n- two")
        guard case .list(let markers, let items)? = unordered.first?.kind else {
            Issue.record("expected a list")
            return
        }
        #expect(markers == ["•", "•"])
        #expect(items.count == 2)

        let ordered = blocks("3. three\n4. four")
        guard case .list(let numbers, _)? = ordered.first?.kind else {
            Issue.record("expected an ordered list")
            return
        }
        #expect(numbers == ["3.", "4."])
    }

    @Test("A timestamp is one run on the grey plate, in the words' own ink")
    func timestamp() {
        let parsed = blocks("Released <t:1790000000:D> today")
        guard case .lines(let lines)? = parsed.first?.kind else {
            Issue.record("expected lines")
            return
        }
        let plated = lines.flatMap { $0 }.compactMap { segment -> ProseStyle? in
            if case .word(_, let style, _) = segment.kind, style.plate == .timestamp { return style }
            return nil
        }
        #expect(plated.count == 1)
        #expect(plated.first?.role == .timestamp)
        #expect(plated.first?.color(base: .primary) == .primary)
    }

    @Test("Headings, subtext and fenced code keep their kinds")
    func otherBlocks() {
        let parsed = blocks("# Big\n-# small\n```\ncode\n```")
        guard case .lines(let heading)? = parsed.first?.kind,
              case .word(_, let headingStyle, _)? = heading.first?.first?.kind
        else {
            Issue.record("expected a heading")
            return
        }
        #expect(headingStyle.role == .heading(1))
        #expect(parsed.contains { if case .code(let code) = $0.kind { code.contains("code") } else { false } })
    }
}
