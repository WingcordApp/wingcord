import SwiftUI
import WingcordCore

// MARK: - The editor's flyouts
//
// docs/CLIPS-PRESENCE.md, Phase 9 — Alex: "replace these sheets with flyouts,
// i just think it looks better" (screenshot 14, "Change Nameplate"). A sheet
// covered the profile it was changing; a flyout hangs off the tile that raised
// it, and **every choice in it lands in the draft at once**, so the profile
// beside it is the preview and there is no Apply. Reset in the save bar takes
// it all back. Only adding a connection stays a sheet — it is a sign-in, not a
// choice.

/// Which flyout is up, and which control it hangs from.
@MainActor
@Observable
final class ProfileFlyouts {
    /// Where a flyout can hang from. One picker can be raised from two places —
    /// the avatar's tile in the rail and the pencil on the card — and only the
    /// one that asked shows it.
    enum Anchor: Hashable {
        case rail
        case card
    }

    struct Request: Hashable {
        var picker: ProfileEditPicker
        var anchor: Anchor
    }

    var open: Request?

    /// A picture picked and waiting to be cropped — held here rather than in
    /// the flyout, because the file panel can close a transient popover on
    /// its way up, and the flyout is reopened onto it.
    var pendingPicture: PendingPicture?

    struct PendingPicture {
        var picker: ProfileEditPicker
        var image: ImageData
        var preview: CGImage
        /// Said under the cropper — a moving picture made still, say.
        var note: String?
    }

    func show(_ picker: ProfileEditPicker, from anchor: Anchor) {
        open = Request(picker: picker, anchor: anchor)
    }

    func close() {
        open = nil
        pendingPicture = nil
    }
}

extension View {
    /// Hangs `picker`'s flyout off this view, shown while it is the open one.
    ///
    /// Inert outside an edit — no flyouts, or no draft, in the environment —
    /// so a view shared with the plain profile can carry it unconditionally.
    func profileFlyout(
        _ picker: ProfileEditPicker,
        at anchor: ProfileFlyouts.Anchor,
        arrowEdge: Edge = .trailing
    ) -> some View {
        modifier(ProfileFlyoutAnchor(picker: picker, anchor: anchor, arrowEdge: arrowEdge))
    }
}

private struct ProfileFlyoutAnchor: ViewModifier {
    var picker: ProfileEditPicker
    var anchor: ProfileFlyouts.Anchor
    var arrowEdge: Edge

    @Environment(ProfileFlyouts.self) private var flyouts: ProfileFlyouts?
    @Environment(ProfileEditor.self) private var editor: ProfileEditor?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if let flyouts, let editor {
            let request = ProfileFlyouts.Request(picker: picker, anchor: anchor)
            content.popover(
                isPresented: Binding(
                    get: { flyouts.open == request },
                    set: { shown in
                        // Clicked away: the flyout goes, and a crop it was
                        // holding with it. (A file panel closing it is earlier
                        // than the picture it brings back, so that one stays.)
                        if !shown, flyouts.open == request {
                            flyouts.open = nil
                            flyouts.pendingPicture = nil
                        }
                    }
                ),
                arrowEdge: arrowEdge
            ) {
                ProfileEditFlyout(picker: picker, editor: editor, close: flyouts.close)
                    .environment(model)
                    .environment(editor)
                    .environment(flyouts)
                    .profileFlyoutAppearance()
            }
        } else {
            content
        }
    }
}

/// What a flyout holds, by picker.
struct ProfileEditFlyout: View {
    var picker: ProfileEditPicker
    var editor: ProfileEditor
    var close: () -> Void

    var body: some View {
        switch picker {
        case .nameplate: CollectibleFlyout(kind: .nameplate, editor: editor)
        case .decoration: CollectibleFlyout(kind: .avatarDecoration, editor: editor)
        case .effect: CollectibleFlyout(kind: .profileEffect, editor: editor)
        case .frame: CollectibleFlyout(kind: .profileFrame, editor: editor)
        case .avatar: PictureFlyout(kind: .avatar, editor: editor, close: close)
        case .banner: PictureFlyout(kind: .banner, editor: editor, close: close)
        case .colours: ProfileColourFlyout(editor: editor)
        case .displayNameStyle: DisplayNameStyleFlyout(editor: editor)
        case .typingIndicator: TypingIndicatorFlyout(editor: editor)
        // Never raised as a flyout — see `ProfilePresenter`.
        case .connection: EmptyView()
        }
    }
}

/// A flyout's frame: its title, an optional action beside it, and the body.
///
/// **No close button and no Apply.** A popover closes by clicking away, which
/// is what macOS people already do, and every choice inside is already in the
/// draft.
struct FlyoutScaffold<Trailing: View, Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var width: CGFloat = 340
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.headline, weight: .bold))
                        .foregroundStyle(InkColor.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.base)
                trailing()
            }
            content()
        }
        .padding(Spacing.margin)
        .frame(width: width, alignment: .leading)
    }
}

extension FlyoutScaffold where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        width: CGFloat = 340,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, width: width, trailing: { EmptyView() }, content: content)
    }
}
