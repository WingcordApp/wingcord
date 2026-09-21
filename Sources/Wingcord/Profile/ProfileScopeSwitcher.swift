import SwiftUI

/// Chooses which profile the editor is changing: the account's own, or the one
/// it wears in a particular server.
///
/// **Every server, in the rail's order, with the reader's nickname there as a
/// second line.** The switcher is how a per-server profile gets *made*, so it
/// cannot list only the servers that already have one; and the nickname is the
/// one fact that tells two similarly named servers apart at a glance, because it
/// is the reader's own.
///
/// **Locked while the draft has unsaved changes.** A draft belongs to one scope.
/// Carrying it across would write a server's nickname as an account name, and
/// dropping it would throw away edits on a mis-click — Discord refuses the
/// switch in the same state, and so does this.
struct ProfileScopeSwitcher: View {
    var scopes: [ProfileEditScope]
    var current: ProfileEditScope
    var isLocked: Bool
    var select: (ProfileEditScope) -> Void

    @Environment(\.motion) private var motion
    @State private var isOpen = false
    @State private var hovered: ProfileEditScope.ID?

    private static let rowHeight: CGFloat = 36
    private static let iconSide: CGFloat = 22
    private static let width: CGFloat = 280

    var body: some View {
        Button { isOpen.toggle() } label: { trigger }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text("Profile"))
            .accessibilityValue(Text(current.title))
            // The system popover's own glass, untouched — see
            // `ServerTagChooser` for why clearing it and painting a SwiftUI
            // glass on the content renders an opaque slab instead.
            .popover(isPresented: $isOpen, arrowEdge: .bottom) { list }
    }

    // MARK: The trigger

    private var trigger: some View {
        HStack(spacing: Spacing.tight) {
            icon(current, side: 20)
            Text(current.title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(InkColor.secondary)
                // Points at the list while it is open.
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 32)
        // Layout first, glass last; `.clear` because it sits on the rail over
        // the card's own colours rather than over neutral chrome.
        .glassEffect(.clear.interactive(), in: .capsule)
        .animation(motion.hover, value: isOpen)
    }

    // MARK: The list

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(scopes) { scope in
                    row(scope)
                }
                if isLocked {
                    Text("Save or reset your changes to switch profiles.")
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.snug)
                        .padding(.vertical, Spacing.tight)
                }
            }
            .padding(Spacing.tight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width)
        .frame(maxHeight: 360)
        .animation(motion.fadeQuick, value: hovered)
    }

    private func row(_ scope: ProfileEditScope) -> some View {
        let isCurrent = scope.id == current.id
        let isEnabled = isCurrent || !isLocked
        return Button {
            isOpen = false
            guard !isCurrent else { return }
            select(scope)
        } label: {
            HStack(spacing: Spacing.snug) {
                icon(scope, side: Self.iconSide)
                VStack(alignment: .leading, spacing: 0) {
                    Text(scope.title)
                        .font(.system(.body))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                    if let subtitle = scope.subtitle {
                        Text(subtitle)
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.tight)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The profile being edited stays lit, as Discord's does — you
                // see where you are before you point at anything.
                if isCurrent || hovered == scope.id {
                    ConcentricRectangle().fill(Palette.hoverFill)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { inside in
            // Written only on a change: the pointer reports at event rate and
            // an equal write still costs a body evaluation.
            let next = inside ? scope.id : (hovered == scope.id ? nil : hovered)
            guard next != hovered else { return }
            hovered = next
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// A server's icon, its initials where it has none, or the person glyph for
    /// the account's own profile — the reference draws that, rather than the
    /// reader's avatar, because the row stands for the profile and not the face.
    @ViewBuilder
    private func icon(_ scope: ProfileEditScope, side: CGFloat) -> some View {
        if scope.scope == .account {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: side))
                .foregroundStyle(InkColor.secondary)
                .frame(width: side, height: side)
        } else if let url = scope.iconURL {
            RemoteImage(url: url, side: side, bucket: .artwork) { Color.clear }
                .frame(width: side, height: side)
                .clipShape(.circle)
        } else {
            Text(scope.monogram)
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(InkColor.secondary)
                .frame(width: side, height: side)
                .background(Palette.surfaceRaised, in: .circle)
        }
    }
}
