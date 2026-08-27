import SwiftUI

/// A circular glass control floating over the media.
///
/// **Its own body of glass, because it is not inside anything.** The bars under
/// the stage are one surface with regions cut into them — a control there must
/// never carry its own material, or it is glass on glass and §4 rule 2 says what
/// that looks like. These float free over the picture, so the material is
/// theirs, and `.interactive()` is right on a target this small: the warp scales
/// with the surface, and at 32 points it reads as the control responding rather
/// than as a wobble.
struct MediaGlassButton: View {
    var systemImage: String
    var label: String
    var isActive = false
    var isEnabled = true
    /// 0...1 while the control's work is running. A ring around the glyph
    /// rather than a spinner replacing it: a control that swaps its icon for a
    /// spinner is a control the reader can no longer identify.
    var progress: Double?
    var action: () -> Void

    @Environment(\.motion) private var motion

    static let side: CGFloat = 34

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.controlGlyph)
                .foregroundStyle(isActive ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(InkColor.primary))
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.02, progress))
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(3)
                            .animation(motion.standard, value: progress)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .interactiveChromeOverMedia(in: .circle)
        .animation(motion.standard, value: isActive)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// One control inside a media bar.
///
/// **A region in the bar's material, never a body on top of it** — the other
/// half of the rule above, and the same shape the now bar's three controls take.
/// A tinted fill inherits the bar's material and reads as part of it.
struct MediaBarControl: View {
    var systemImage: String
    var label: String
    var isActive = false
    var isEnabled = true
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.controlGlyph)
                .foregroundStyle(foreground)
                .frame(width: Metrics.control, height: Metrics.control)
                .background { Circle().fill(fill) }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: isActive)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var foreground: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Ink.tertiary) }
        return isActive ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(InkColor.primary)
    }

    private var fill: Color {
        if isActive { return Palette.accent.opacity(0.22) }
        return .white.opacity(isHovering && isEnabled ? 0.16 : 0.08)
    }
}

/// Everything a reader does with the picture once they have looked at it, as a
/// cluster of floating controls.
///
/// **No bar behind them.** A full-width slab across the top of a lightbox is
/// chrome the width of the window spent on three controls, and it covers the top
/// of the very thing it is floating over. One `GlassEffectContainer` renders the
/// three as a single piece of material carrying three shapes, which is what the
/// picker's chrome already does and what stops adjacent glass doubling where it
/// meets.
struct MediaActionCluster: View {
    var item: MediaItem
    var authorName: String
    var sentAt: Date
    var actions: MediaActions
    var canCopyImage: Bool
    var copyImage: () -> Void

    /// **One popover on one view**, which is what makes a presentation modifier
    /// legitimate here. The rule it would otherwise break — never a `.popover`
    /// in a row — exists because a popover written into a list is evaluated by
    /// every row on every pass. There is exactly one of these.
    @State private var isInfoShown = false

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                MediaGlassButton(
                    systemImage: "info.circle",
                    label: "Details",
                    isActive: isInfoShown,
                    action: { isInfoShown = true }
                )
                .popover(isPresented: $isInfoShown, arrowEdge: .bottom) {
                    MediaInfoCard(item: item, authorName: authorName, sentAt: sentAt)
                        // The card supplies its own material, so the popover
                        // must supply none — two in series read as frost rather
                        // than as glass.
                        .presentationBackground(.clear)
                }

                MediaGlassButton(
                    systemImage: actions.savedURL == nil ? "arrow.down" : "checkmark",
                    label: "Save…",
                    isActive: actions.savedURL != nil,
                    isEnabled: actions.saveProgress == nil,
                    progress: actions.saveProgress,
                    action: { actions.save(item) }
                )

                MediaOverflowMenu(
                    item: item,
                    actions: actions,
                    canCopyImage: canCopyImage,
                    copyImage: copyImage
                )
            }
        }
    }
}

/// The rest of the actions, one press deeper.
///
/// **A menu rather than four more circles.** Save and Details are what people
/// come for; copying a link, copying the picture, opening it in a browser and
/// showing the saved file are each worth having and none is worth a permanent
/// control floating over somebody's photograph.
private struct MediaOverflowMenu: View {
    var item: MediaItem
    var actions: MediaActions
    var canCopyImage: Bool
    var copyImage: () -> Void

    var body: some View {
        Menu {
            Button("Copy Link", systemImage: "link") { actions.copyLink(item) }
            if canCopyImage {
                Button("Copy Image", systemImage: "doc.on.doc", action: copyImage)
            }
            Button("Open in Browser", systemImage: "safari") { actions.openInBrowser(item) }
            if actions.savedURL != nil {
                Divider()
                Button("Show in Finder", systemImage: "folder") { actions.revealSavedFile() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Typeface.controlGlyph)
                .foregroundStyle(InkColor.primary)
                .frame(width: MediaGlassButton.side, height: MediaGlassButton.side)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .interactiveChromeOverMedia(in: .circle)
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}
