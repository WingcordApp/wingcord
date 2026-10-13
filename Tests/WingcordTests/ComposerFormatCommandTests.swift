import AppKit
import SwiftUI
import Testing
@testable import Wingcord

/// The menu bar's Format menu, arriving at a real composer field.
///
/// The menu reaches the field down the responder chain; what is pinned here is
/// everything after that — the field takes the command as its sender and the
/// edit lands in the text, through the same path the selection toolbar uses.
@MainActor
struct ComposerFormatCommandTests {

    private final class Draft {
        var text: String
        var isFocused = true
        init(_ text: String) { self.text = text }
    }

    private func field(holding text: String) throws -> (MarkdownTextView, NSWindow, Draft) {
        _ = NSApplication.shared
        let draft = Draft(text)
        let editor = MarkdownEditor(
            text: Binding(get: { draft.text }, set: { draft.text = $0 }),
            isFocused: Binding(get: { draft.isFocused }, set: { draft.isFocused = $0 }),
            placeholder: "Message",
            font: .systemFont(ofSize: 13),
            lines: 1...6
        )
        let host = NSHostingView(rootView: editor.frame(width: 320))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let textView = try #require(find(in: host))
        return (textView, window, draft)
    }

    private func find(in view: NSView) -> MarkdownTextView? {
        if let field = view as? MarkdownTextView { return field }
        for subview in view.subviews {
            if let field = find(in: subview) { return field }
        }
        return nil
    }

    @Test("Bold, a heading and a code block land in the field's text")
    func formatsLand() throws {
        let (field, window, draft) = try field(holding: "hello")
        defer { window.close() }

        field.setSelectedRange(NSRange(location: 0, length: 5))
        field.applyComposerFormat(ComposerFormatCommand(.format(.bold)))
        #expect(field.string == "**hello**")
        #expect(draft.text == "**hello**", "the draft hears the edit")

        field.applyComposerFormat(ComposerFormatCommand(.linePrefix("# ")))
        #expect(field.string == "# **hello**")

        field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length))
        field.applyComposerFormat(ComposerFormatCommand(.codeBlock))
        #expect(field.string == "```\n# **hello**\n```")
    }

    @Test("Add @mention types an @ at the caret")
    func insertTypes() throws {
        let (field, window, _) = try field(holding: "hi ")
        defer { window.close() }
        field.setSelectedRange(NSRange(location: 3, length: 0))
        field.applyComposerFormat(ComposerFormatCommand(.insert("@")))
        #expect(field.string == "hi @")
    }
}
