import AppKit

/// What the menu bar's Format menu, and Edit › Send Message, ask of the
/// composer being typed in.
///
/// **Sent down the responder chain, not through the store.** The menu does not
/// know which composer has the caret — the channel's, a thread's, an edit in
/// place — and the first responder does: `NSApp.sendAction` delivers this to
/// whichever `MarkdownTextView` is focused, as the sender, and to nothing when
/// none is. That is AppKit's own way for a menu command to reach the view it is
/// about.
final class ComposerFormatCommand: NSObject {
    enum Action: Hashable {
        /// A mark around the selection — `FormattingToggle.toggle`.
        case format(MarkdownFormat)
        case quote
        /// A fenced block on lines of its own.
        case codeBlock
        /// A line prefix: `# `, `## `, `### ` or `-# `.
        case linePrefix(String)
        /// Words typed at the caret, which the composer then reads as anyone
        /// typing them — `@` opens the mention list, `@time` the time picker.
        case insert(String)
        /// Edit › Send Message: what Return does, whatever the list over the
        /// field is offering.
        case send
    }

    let action: Action

    init(_ action: Action) {
        self.action = action
    }

    /// Sends it to the focused composer, if there is one.
    @MainActor
    static func send(_ action: Action) {
        NSApp.sendAction(
            #selector(MarkdownTextView.applyComposerFormat(_:)),
            to: nil,
            from: ComposerFormatCommand(action)
        )
    }
}
