import Foundation
import WingcordCore

/// One text file's preview: what was fetched of it, and how its card is set.
///
/// The card's settings are Discord's `eC` state — folded, the file's own
/// language, Wrap Text and Render Markdown on — and live as long as the
/// session, so a card scrolled away and back is the card the reader left.
struct PlaintextPreviewState: Equatable {
    enum Contents: Equatable {
        case loading
        case loaded(text: String, bytesLeft: Int)
        /// Discord's `hadError`: the card gives way to a file card.
        case failed
    }

    var contents: Contents = .loading
    var isExpanded = false
    var language: String
    var wrapsText = true
    var rendersMarkdown = true

    init(language: String) {
        self.language = language
    }

    /// Render Markdown, where the language is one it applies to.
    var showsMarkdown: Bool {
        rendersMarkdown && PlaintextPreview.markdownLanguages.contains(language)
    }
}

extension AppModel {

    /// The preview's state, or its first: loading, in the file's language.
    func plaintextPreview(_ key: PlaintextCardKey) -> PlaintextPreviewState {
        plaintextPreviews[key.attachmentID]
            ?? PlaintextPreviewState(language: PlaintextPreview.language(ofFilename: key.filename))
    }

    func updatePlaintextPreview(_ key: PlaintextCardKey, _ change: (inout PlaintextPreviewState) -> Void) {
        var state = plaintextPreview(key)
        change(&state)
        guard state != plaintextPreviews[key.attachmentID] else { return }
        plaintextPreviews[key.attachmentID] = state
    }

    /// Fetches the start of the file, once — Discord's preview asks as it
    /// mounts. A file that cannot be fetched or read gives its place back to
    /// a file card: its measure goes, so the row lays out the card instead.
    func loadPlaintextPreview(_ key: PlaintextCardKey) async {
        guard plaintextPreview(key).contents == .loading,
              plaintextFetches.insert(key.attachmentID).inserted,
              let url = URL(string: key.url)
        else { return }
        let contents: PlaintextPreviewState.Contents
        do {
            let response = try await ImageStore.shared.textPreview(url)
            let bytesLeft = PlaintextPreview.bytesLeft(
                contentRange: response.contentRange,
                contentLength: response.contentLength
            )
            contents = PlaintextPreview.text(of: response.data, contentType: key.contentType, bytesLeft: bytesLeft)
                .map { .loaded(text: $0, bytesLeft: bytesLeft) } ?? .failed
        } catch {
            contents = .failed
        }
        updatePlaintextPreview(key) { $0.contents = contents }
        if contents == .failed, hostedCardSizes.removeValue(forKey: .plaintext(key)) != nil {
            cardRevision &+= 1
        }
    }
}
