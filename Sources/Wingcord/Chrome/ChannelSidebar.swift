import SwiftUI
import WingcordCore

/// The channel column: the server's banner, its name pill, and its channels.
///
/// **No background.** Like the rail, this sits inside the split view's sidebar
/// column and the vibrancy behind it is the wallpaper coming through. The banner
/// is the only thing here with a colour of its own, and it is a *layer* rather
/// than the first row of the list.
///
/// That split matters. As the first row, the banner forces the scroll view to
/// give up its top safe area — the only way for artwork inside a scroll view to
/// reach the top of the column — and a scroll view with no top safe area pins
/// its content to the top of the window rather than under the toolbar. Split
/// apart, the banner reaches the chrome and the list keeps its inset, and the
/// two stay in step because both are driven by the same measured offset.
struct ChannelSidebar: View, Equatable {
    var presentation: SidebarPresentation
    var selectedChannelID: ChannelID?

    static func == (lhs: ChannelSidebar, rhs: ChannelSidebar) -> Bool {
        lhs.presentation == rhs.presentation && lhs.selectedChannelID == rhs.selectedChannelID
    }

    var selectChannel: (ChannelID) -> Void = { _ in }
    var toggleCategory: (ChannelID) -> Void = { _ in }
    var openGuildMenu: () -> Void = {}

    @Environment(\.motion) private var motion
    /// Shared namespace so the selection pill *flows* from row to row rather
    /// than fading in at the new position.
    @Namespace private var selectionNamespace
    /// How far the list has been scrolled: zero at rest, positive downward.
    ///
    /// Read once from the scroll view's own geometry rather than inferred from a
    /// reader inside the content — a reader in there measures the *content's*
    /// frame, which the stretchy banner is already deforming.
    @State private var scrollOffset: CGFloat = 0

    /// Tall enough that the name pill sits on colour rather than straddling the
    /// edge between artwork and list. Below roughly this the glass has nothing
    /// to lens for most of its body and the pill reads as a toolbar.
    private var bannerHeight: CGFloat { 116 }

    private var hasBanner: Bool { presentation.header?.hasBanner ?? false }

    /// Vertical room the pill occupies, its own breathing space included.
    private var pillSlot: CGFloat { Metrics.control + Spacing.base }

    /// Where the pill sits with the list at the top: on the banner's lower edge,
    /// which is the whole reason the banner is tall enough to have one. With no
    /// banner there is no travel to do and the pill is parked from the first
    /// frame.
    private var pillRestY: CGFloat { hasBanner ? bannerHeight - pillSlot : 0 }

    /// The pill's current top edge. It travels 1:1 with the scroll and stops at
    /// the top of the column.
    private var pillY: CGFloat { max(0, pillRestY - scrollOffset) }

    /// Whether there is still artwork behind the pill, which is what decides its
    /// material.
    ///
    /// Measured against the pill's own midpoint rather than either edge, so the
    /// material changes when the ground behind it is half and half — both the
    /// least visible moment to switch and the most honest one.
    private var isPillOverBanner: Bool {
        guard hasBanner else { return false }
        return bannerHeight - scrollOffset > pillY + Metrics.control / 2
    }

    /// Empty room at the head of the list, standing in for the banner.
    ///
    /// The banner is not in the list — it is a layer behind it — so the content
    /// has to reserve the space it occupies or the first rows are drawn
    /// underneath the artwork.
    ///
    /// **The whole banner, not the banner minus the pill.** The pill FLOATS over
    /// both; it takes no space in either. Subtracting its slot here left the
    /// first row starting a pill's height too high, which is exactly the amount
    /// by which "Channels & Roles" appeared behind the artwork.
    private var bannerReserve: CGFloat {
        hasBanner ? bannerHeight + Spacing.base : 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasBanner, let header = presentation.header {
                SidebarBanner(
                    header: header,
                    naturalHeight: bannerHeight,
                    scrollOffset: scrollOffset
                )
            }
            list
        }
        // Over both layers, so it can sit on the banner at rest and over the
        // channel list once parked.
        //
        // Inside the scroll view it could only do one of two things: scroll away
        // with the content, or pin and never move. What is wanted is neither —
        // it travels while there is banner above it, then stops. That is a
        // position rather than a layout, so it is drawn on top and told where to
        // be. Nothing here blocks the scroll: the row is a menu button and a
        // spacer, and a spacer has no hit region of its own.
        .overlay(alignment: .topLeading) {
            if let header = presentation.header {
                ServerNamePill(
                    name: header.name,
                    overMedia: isPillOverBanner,
                    action: openGuildMenu
                )
                .padding(.horizontal, Spacing.snug)
                .offset(y: pillY)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if bannerReserve > 0 {
                    Color.clear
                        .frame(height: bannerReserve)
                        .accessibilityHidden(true)
                }

                ForEach(presentation.rows) { row in
                    switch row {
                    case .guildAction(let action):
                        SidebarActionRow(action: action)
                    case .category(let category):
                        SidebarCategoryRow(
                            category: category,
                            toggle: { toggleCategory(category.id) }
                        )
                    case .channel(let channel):
                        SidebarChannelRow(
                            channel: channel,
                            isSelected: channel.id == selectedChannelID,
                            namespace: selectionNamespace,
                            action: { selectChannel(channel.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.top, hasBanner ? 0 : pillSlot)
            .padding(.bottom, Spacing.base)
        }
        .scrollIndicators(.never)
        // One read, feeding both the banner's stretch and the pill's travel.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // A `@State` write of an equal value still invalidates, and this one
            // fires on every scroll tick.
            guard abs(scrollOffset - offset) > 0.5 else { return }
            scrollOffset = offset
        }
        .softScrollEdgesVertical()
    }
}

/// The server's name, at rest on the banner's lower edge and parked under the
/// chrome once the list has been scrolled that far.
///
/// Sized down from a standalone floating control: at full size with a headline
/// inside, the name reads as a page title with a whole navigation bar's weight
/// behind it, on a column that already has the rail and the now bar competing
/// for attention.
///
/// **The pill hugs its label — its width IS the text's width**, so "Lumen Club"
/// and "Krxqz | Cfgs, Clients and more" are visibly different objects rather
/// than the same slab with different contents. `.fixedSize()` before the glass
/// is what does it: the material has to be applied to the final hugged geometry,
/// and a `.frame(maxWidth:)` anywhere above it defeats the whole effect.
///
/// Switching servers **animates that width** rather than snapping it. The name
/// is the animation's value, so the capsule reflows to the new label and the
/// glass morphs with it; without the value the two names cut, and a capsule that
/// changes size instantaneously reads as two different controls rather than as
/// one control being re-labelled.
struct ServerNamePill: View {
    var name: String
    var overMedia: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Spacing.base) {
            Menu {
                ServerMenuContent(action: action)
            } label: {
                HStack(spacing: Spacing.tight) {
                    Text(name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(overMedia ? AnyShapeStyle(InkColor.primary) : AnyShapeStyle(Ink.primary))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(overMedia ? AnyShapeStyle(InkColor.secondary) : AnyShapeStyle(Ink.secondary))
                }
                .padding(.horizontal, Spacing.snug)
                .frame(minHeight: Metrics.control)
                .contentShape(.capsule)
            }
            // `.button` + `.plain` + a content shape, THEN the glass. The
            // borderless style with `.fixedSize` collapses the label frame on
            // this platform.
            .menuStyle(.button)
            .buttonStyle(.plain)
            // Hugs the label. Everything above this in the chain must leave the
            // width alone.
            .fixedSize()
            .modifier(PillChrome(overMedia: overMedia))
            .animation(motion.glassMorph, value: name)
            .accessibilityLabel(Text(name))
            .accessibilityHint("Server options")

            // The spacer keeps the pill leading-aligned instead of centring
            // itself across the column, and it is also what stops the overlay
            // swallowing scroll: a spacer has no hit region.
            Spacer(minLength: Spacing.base)
        }
    }
}

/// Picks the pill's material from what is behind it.
///
/// A `ViewModifier` rather than an `if` in the builder, because the two branches
/// are different view types and switching between them replaces the control's
/// identity — so the pill would pop rather than change material when a banner
/// finishes loading.
private struct PillChrome: ViewModifier {
    var overMedia: Bool

    func body(content: Content) -> some View {
        if overMedia {
            content.interactiveChromeOverMedia()
        } else {
            content.interactiveChrome()
        }
    }
}

private struct ServerMenuContent: View {
    var action: () -> Void

    var body: some View {
        Button("Invite People", systemImage: "person.badge.plus", action: action)
        Button("Server Settings", systemImage: "gearshape", action: action)
        Divider()
        Button("Mark as Read", systemImage: "checkmark.message", action: action)
        Divider()
        Button("Leave Server", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: action)
    }
}
