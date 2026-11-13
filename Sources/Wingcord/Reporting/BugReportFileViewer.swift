import AppKit
import SwiftUI

/// One file of the report, as it would go: text in a read-only, selectable
/// view; a picture as itself.
struct BugReportFileViewer: View {
    var file: BugReportContents.File?

    var body: some View {
        Group {
            if let file, file.kind == .image, let image = NSImage(data: file.data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Spacing.base)
                    .accessibilityLabel(Text("Picture of the Wingcord window"))
            } else if let file {
                ReportTextView(
                    text: file.text ?? "",
                    identity: file.name + "/\(file.data.count)",
                    startsAtEnd: file.name == "log.txt"
                )
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modalFieldGround()
        .clipShape(.rect(cornerRadius: Radius.chip))
    }
}

/// Read-only text that can be megabytes long — the log — which a SwiftUI
/// `Text` would lay out whole on every pass. AppKit's text view lays out what
/// is on screen.
///
/// **The text is set only when the file changes**, keyed by `identity`: a
/// representable that reset four megabytes on every update would scroll back
/// to the top under the reader.
struct ReportTextView: NSViewRepresentable {
    var text: String
    var identity: String
    /// The log reads newest last, and the newest is what the report is about.
    var startsAtEnd: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: Spacing.base, height: Spacing.base)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.identity != identity,
              let textView = scroll.documentView as? NSTextView
        else { return }
        context.coordinator.identity = identity
        textView.string = text
        if startsAtEnd {
            textView.scrollToEndOfDocument(nil)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var identity: String?
    }
}
