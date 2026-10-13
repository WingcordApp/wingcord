import SwiftUI

/// A link-like button: plain words, underlined while the pointer is on them —
/// Discord's `clickableText:hover`, and its event card's linkable server name
/// and room (`.guildNameLinkable_da5e8d`, `.channelLocationLink_da5e8d`).
///
/// **The hover lives in a view the style returns**, not on the style: a style
/// is a recipe the button reads, and state kept on it is not the button's.
struct UnderlinesOnHover: ButtonStyle {
    /// Whether the words go anywhere — words that do not stay plain.
    var isLive = true

    func makeBody(configuration: Configuration) -> some View {
        Words(label: configuration.label, isLive: isLive)
    }

    private struct Words: View {
        var label: Configuration.Label
        var isLive: Bool

        @State private var isHovering = false

        var body: some View {
            label
                .underline(isLive && isHovering)
                .contentShape(.rect)
                .onHover { hovering in
                    guard isHovering != hovering else { return }
                    isHovering = hovering
                }
        }
    }
}
