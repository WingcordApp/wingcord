import SwiftUI

/// A right-click on somebody's name in a profile: the name as drawn, and the
/// username.
///
/// **A styled name cannot be selected** — it is a drawn view, one run of
/// glyphs per effect layer — so a right-click is the only way to take it.
/// Both labels are Discord's own: Copy Text is its message menu's, and Copy
/// Username its account popout's, which copies `getUserTag` with
/// `identifiable: "always"` — the handle with a legacy discriminator kept.
struct NameCopyMenu: ViewModifier {
    var displayName: String
    var handle: String

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Copy Text", systemImage: "doc.on.doc") { AppModel.copy(displayName) }
            Button("Copy Username", systemImage: "at") { AppModel.copy(handle) }
        }
    }
}

extension View {
    /// See `NameCopyMenu`.
    func nameCopyMenu(displayName: String, handle: String) -> some View {
        modifier(NameCopyMenu(displayName: displayName, handle: handle))
    }
}
