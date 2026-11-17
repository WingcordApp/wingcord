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
    /// Nil where the style cannot be changed — a server profile without Nitro.
    var editStyle: (() -> Void)?

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

            if let editStyle {
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
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        // **32, as the routes take** — a display name and a nickname alike.
        // Found out at Save, a longer one cost every other edit in the sheet.
        .onChange(of: text) { _, edited in
            if edited.count > Self.limit { text = String(edited.prefix(Self.limit)) }
        }
        .animation(motion.hover, value: isFocused)
        .animation(motion.hover, value: isHovering)
    }

    /// `global_name` and `nick` both stop at 32.
    static let limit = 32
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

    @Environment(\.motion) private var motion
    @State private var isOpen = false
    @State private var hovered: GuildID?
    @State private var isNoneHovered = false

    private static let rowHeight: CGFloat = 34
    private static let iconSide: CGFloat = 22
    private static let width: CGFloat = 264

    var body: some View {
        Button { isOpen.toggle() } label: { chip }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text("Server tag"))
            .accessibilityValue(Text(current?.name ?? "None"))
            // **The system popover's own glass, untouched.** On macOS 26 an
            // `NSPopover` draws Liquid Glass at the window level, sampling the
            // app behind it — which is what makes it transparent. Clearing that
            // (`.presentationBackground(.clear)`) and painting a SwiftUI glass
            // on the content instead gives a glass with nothing behind it to
            // lens: it lives inside the popover's own window, so it renders as
            // a flat grey slab. The row highlights are the only paint here.
            .popover(isPresented: $isOpen, arrowEdge: .bottom) { list.profileFlyoutAppearance() }
    }

    // MARK: The chip

    /// **The badge comes with the letters, because the letters alone are not the
    /// tag.** Discord draws the little diamond, leaf or crest ahead of them and
    /// two servers can easily share four characters.
    private var chip: some View {
        HStack(spacing: 4) {
            if let badge = current?.badgeURL {
                RemoteImage(url: badge, side: 14, bucket: .artwork) { Color.clear }
                    .frame(width: 14, height: 14)
            }
            Text(current?.tag.isEmpty == false ? current!.tag : "Server Tag")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(current == nil ? InkColor.tertiary : InkColor.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(InkColor.tertiary)
                // Points at the list while it is open, which is the cheapest
                // possible statement of where the thing went.
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        // Layout first, glass last — and `.clear`, never `.regular`: what passes
        // under this is somebody's own banner, which `INVARIANTS.md` §4 says
        // must lens rather than frost.
        .glassEffect(.clear.tint(Palette.flyoutTint).interactive(), in: .capsule)
        .animation(motion.hover, value: isOpen)
    }

    // MARK: The list

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                noneRow
                ForEach(options) { option in
                    row(option)
                }
            }
            .padding(.vertical, Spacing.tight)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width)
        .frame(maxHeight: 280)
        .animation(motion.fadeQuick, value: hovered)
    }

    private var noneRow: some View {
        Button {
            selection = nil
            isOpen = false
        } label: {
            HStack(spacing: Spacing.snug) {
                Text("No Server Tag")
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .italic()
                Spacer(minLength: Spacing.tight)
                if selection == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(InkColor.secondary)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight(isNoneHovered || selection == nil) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isNoneHovered = $0 }
    }

    private func row(_ option: ServerTagOption) -> some View {
        Button {
            selection = option.id
            isOpen = false
        } label: {
            HStack(spacing: Spacing.snug) {
                icon(option)
                Text(option.name)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.tight)
                GuildTagChip(
                    tag: GuildTag(
                        text: option.tag,
                        badgeURL: option.badgeURL,
                        guildID: option.id
                    )
                )
                if selection == option.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(InkColor.secondary)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight(hovered == option.id || selection == option.id) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // Written only on a change: the pointer generates these at event
            // rate and an equal write still costs a body evaluation.
            let next = inside ? option.id : (hovered == option.id ? nil : hovered)
            guard next != hovered else { return }
            hovered = next
        }
        .accessibilityLabel(Text("\(option.name), tag \(option.tag)"))
    }

    /// A server's icon, or its initials where it has none — the same fallback
    /// the rail's tiles draw.
    @ViewBuilder
    private func icon(_ option: ServerTagOption) -> some View {
        if let url = option.iconURL {
            RemoteImage(url: url, side: Self.iconSide, bucket: .artwork) {
                Color.clear
            }
            .frame(width: Self.iconSide, height: Self.iconSide)
            .clipShape(.circle)
        } else {
            Text(option.monogram)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(InkColor.secondary)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .background(Palette.surfaceRaised, in: .circle)
        }
    }

    /// **Concentric with the popover**, so a highlighted row's corners follow
    /// the glass around it instead of sitting as a smaller, differently-rounded
    /// box inside a rounded one.
    @ViewBuilder
    private func highlight(_ isHovered: Bool) -> some View {
        if isHovered {
            ConcentricRectangle()
                .fill(Palette.hoverFill)
                .padding(.horizontal, Spacing.tight)
        }
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
    /// The server's own icon, drawn at the head of its row.
    ///
    /// **A tag is four letters and several servers pick the same four.** The
    /// icon is what tells RENO from RENO, which is why Discord's own list leads
    /// with it rather than with the name.
    var iconURL: URL?
    var monogram: String = "?"
}

/// The pencil that opens a menu over the avatar or the banner.
///
/// **A menu, not a jump straight to a picker.** Both surfaces carry two
/// cosmetics apiece — the avatar has its decoration, the banner has the effect
/// and the frame — so a click has to ask which, and Discord's own answer is a
/// short menu anchored on the thing being changed.
///
/// **It appears on hover and is otherwise absent.** These sit on top of the
/// artwork somebody is editing — a face, a banner — and two permanent slabs
/// over that artwork are two things competing with the thing being judged. The
/// editor's promise is that the card beside the controls shows what the change
/// will look like, which a control parked on top of it undermines.
struct EditOverlayButton<Menu: View>: View {
    /// Whether the surface under this is being pointed at.
    var isVisible: Bool
    @ViewBuilder var menu: () -> Menu

    @Environment(\.motion) private var motion
    /// **Reveals for VoiceOver unconditionally.** A hover-only control is a
    /// control a reader who never hovers cannot reach at all — opacity zero and
    /// no hit testing removes it from the accessibility tree as surely as
    /// deleting it. Pointer users get the clean artwork; everybody else gets
    /// the button.
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
    /// Hover on the control itself as well as on the surface under it, so the
    /// pointer crossing onto the pencil — or AppKit holding it highlighted
    /// while its own menu is up — cannot make it disappear from under the list
    /// it just opened.
    @State private var isSelfHovered = false

    private var isShown: Bool { isVisible || isSelfHovered || isVoiceOverRunning }

    var body: some View {
        SwiftUI.Menu {
            menu()
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                // Layout first, glass last. `.clear` because what passes under
                // is the reader's own artwork — §4's rule: a sampled material
                // over a picture must lens rather than frost.
                .glassEffect(.clear.interactive(), in: .circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // **Scale with the fade, not a bare opacity.** A glass surface arriving
        // should read as a material condensing out of the background rather
        // than a decal switching on — and the pair is what makes the appearance
        // legible at the speed a pointer moves.
        .scaleEffect(isShown ? 1 : 0.86)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .onHover { isSelfHovered = $0 }
        .animation(motion.hover, value: isShown)
        .accessibilityLabel(Text("Edit"))
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
    @State private var isFocused = false
    @State private var isPickingEmoji = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Discord's box, as in the composer: a bio is markdown and is drawn
            // as markdown, so it is written as markdown. See `MarkdownEditor`.
            MarkdownEditor(
                text: $text,
                isFocused: $isFocused,
                placeholder: "Tell people about yourself",
                // The size it's read at, so the words don't jump on Edit.
                font: NSFont.systemFont(ofSize: ProseText.bioPointSize),
                lines: 3...6,
                characterLimit: Self.limit
            )
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

            HStack(spacing: Spacing.base) {
                // **Discord's bio box has an emoji button, and so does this
                // one** — the composer's own picker, so a custom emoji goes in
                // as the same markup a message would carry.
                Button("Add Emoji", systemImage: "face.smiling", action: { isPickingEmoji = true })
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(InkColor.secondary)
                    .help("Add an emoji")
                    .popover(isPresented: $isPickingEmoji, arrowEdge: .bottom) {
                        ExpressionPicker(mode: .emoji, onPick: insert, onPickGIF: { _ in })
                            .presentationBackground(.clear)
                            .profileFlyoutAppearance()
                    }
                Spacer(minLength: 0)
                Text("\(text.count) / \(Self.limit)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    // Turns as it fills, so the ceiling is felt before it is hit.
                    .foregroundStyle(
                        text.count >= Self.limit ? Palette.destructive : InkColor.secondary
                    )
            }
        }
        .animation(motion.hover, value: isFocused)
    }

    /// Puts a picked emoji at the end of the bio — or nowhere, with a bump,
    /// when it would run past the route's ceiling.
    private func insert(_ item: ExpressionItem) {
        guard case .insert(let insertion) = item.pick else { return }
        // Appended, not run through the shortcode completer — that replaces
        // from the last colon, and a bio's colons are prose.
        let next = text + insertion
        guard next.count <= Self.limit else {
            Haptics.bump()
            return
        }
        text = next
        isPickingEmoji = false
    }
}
