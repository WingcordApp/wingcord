import SwiftUI
import WingcordCore

// The parts of the profile that are edited on the profile itself.
//
// **In place, not in the rail.** A name, a pronoun and a server tag are read
// where they are written — the rail is for cosmetics, which are grids of
// artwork and cannot be typed. Discord splits it the same way, and it is why the
// editor is a mode on this sheet rather than a separate surface.

/// The display name, as a field, with the style chooser beside it.
struct EditableDisplayName: View {
    @Binding var text: String
    var placeholder: String
    var style: DisplayNameStyle?
    var editStyle: () -> Void

    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.base) {
            // **A field that looks like the name until it is touched.** A boxed
            // input sitting permanently where the name goes makes the profile
            // read as a form; the border arrives on hover and focus, which is
            // what says it is editable without saying it constantly.
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .focused($isFocused)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.tight)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isFocused || isHovering ? Palette.hoverFill : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.accentColor : .clear,
                            lineWidth: 1.5
                        )
                }

            Button(action: editStyle) {
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))
            .help("Edit Style")
            .accessibilityLabel(Text("Edit display name style"))
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isFocused)
        .animation(motion.hover, value: isHovering)
    }
}

/// A short line — a pronoun — edited where it is read.
struct EditableInlineField: View {
    @Binding var text: String
    var placeholder: String
    var limit: Int

    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(InkColor.secondary)
            .lineLimit(1)
            .fixedSize()
            .focused($isFocused)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.accentColor : Palette.railHairline,
                        lineWidth: 1
                    )
            }
            // **Truncated as it is typed, not rejected on save.** The route caps
            // pronouns at 40 and a bio at 190, and finding that out from a
            // rejected save is finding it out too late.
            .onChange(of: text) { _, edited in
                if edited.count > limit { text = String(edited.prefix(limit)) }
            }
            .animation(motion.hover, value: isFocused)
    }
}

/// Which server's tag the reader wears, if any.
///
/// **Only servers that actually have one.** A guild without `GUILD_TAGS` cannot
/// lend a tag, so listing it is offering something that would fail — and the
/// list is short enough on most accounts that the filter is the difference
/// between a menu and a directory.
struct ServerTagChooser: View {
    var options: [ServerTagOption]
    @Binding var selection: GuildID?

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                Label {
                    Text("No Server Tag")
                } icon: {
                    if selection == nil { Image(systemName: "checkmark") }
                }
            }
            if !options.isEmpty { Divider() }
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    Label {
                        Text("\(option.name)  \(option.tag)")
                    } icon: {
                        if selection == option.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.tight) {
                Text(current?.tag ?? "Server Tag")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current == nil ? InkColor.tertiary : InkColor.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(InkColor.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .chromeOverMedia(tinted: Palette.flyoutTint)
        .accessibilityLabel(Text("Server tag"))
    }

    private var current: ServerTagOption? {
        options.first { $0.id == selection }
    }
}

/// One server the reader could wear the tag of.
struct ServerTagOption: Hashable, Sendable, Identifiable {
    var id: GuildID
    var name: String
    var tag: String
    var badgeURL: URL?
}

/// The pencil that opens a menu over the avatar or the banner.
///
/// **A menu, not a jump straight to a picker.** Both surfaces carry two
/// cosmetics apiece — the avatar has its decoration, the banner has the effect
/// and the frame — so a click has to ask which, and Discord's own answer is a
/// short menu anchored on the thing being changed.
struct EditOverlayButton<Menu: View>: View {
    var isVisible: Bool
    @ViewBuilder var menu: () -> Menu

    var body: some View {
        if isVisible {
            SwiftUI.Menu {
                menu()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.black.opacity(0.55))
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .transition(.opacity)
            .accessibilityLabel(Text("Edit"))
        }
    }
}

/// The bio, edited where it is read, with the route's own ceiling on it.
///
/// **190 characters, counted as they are typed.** `PATCH /users/@me/profile`
/// caps it there and rejects the whole body for a longer one — so the count is
/// shown and the field stops accepting rather than letting somebody write four
/// paragraphs and lose all of them at Save.
struct EditableBioField: View {
    @Binding var text: String

    /// The route's limit.
    static let limit = 190

    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField("Tell people about yourself", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.primary)
                .lineLimit(3...6)
                .focused($isFocused)
                .padding(Spacing.base)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.hoverFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.accentColor : Palette.railHairline,
                            lineWidth: 1
                        )
                }
                .onChange(of: text) { _, edited in
                    if edited.count > Self.limit {
                        text = String(edited.prefix(Self.limit))
                    }
                }

            Text("\(text.count) / \(Self.limit)")
                .font(.system(size: 10))
                .monospacedDigit()
                // Turns as it fills, so the ceiling is felt before it is hit.
                .foregroundStyle(
                    text.count >= Self.limit ? Palette.destructive : InkColor.tertiary
                )
        }
        .animation(motion.hover, value: isFocused)
    }
}
