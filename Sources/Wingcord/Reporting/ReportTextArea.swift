import AppKit
import SwiftUI

/// One of the form's text areas: the editor in the card's field well, lit
/// while it has the keyboard.
struct ReportTextArea: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var lines: ClosedRange<Int>

    var body: some View {
        MarkdownEditor(
            text: $text,
            isFocused: $isFocused,
            placeholder: placeholder,
            font: NSFont.preferredFont(forTextStyle: .body),
            lines: lines,
            characterLimit: 4_000
        )
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .modalFieldGround(isFocused: isFocused)
    }
}
