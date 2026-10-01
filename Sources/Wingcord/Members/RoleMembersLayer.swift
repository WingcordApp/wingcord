import SwiftUI
import WingcordCore

/// The holders of a role, beside the mention that was clicked — Discord's role
/// popout (`593284`), drawn with the member list's own rows.
///
/// **A layer in the window, not a popover**, for the reason the profile card is
/// one: the rows are the member list's drawn canvas, and a canvas reports a
/// clicked row in its own window's root space. Inside a popover that is the
/// popover's window, and the profile a row opens would land somewhere
/// believable and wrong — `INVARIANTS.md` §1. Drawn under the profiles'
/// presenter, so a card opened from a row comes up above it.
///
/// **Opaque, like the profile card it opens.** It is a list of names over the
/// transcript with nothing dimming the transcript behind it, which is §1's
/// "a reading surface is opaque" case rather than §4's.
struct RoleMembersLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var presentation = PresentationRevision.shared

    static let width: CGFloat = 280
    /// The tallest the list grows before it scrolls.
    static let maximumHeight: CGFloat = 520

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let request = model.roleMembersRequest {
                    // Outside the card and Escape, as one control — see
                    // `ProfilePresenter.dismissLayer`. No scrim: a list beside
                    // a mention interrupts nothing.
                    Button { model.roleMembersRequest = nil } label: {
                        Color.clear.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .cancelAction(unless: model.isCovered(.roleMembers))
                    .accessibilityLabel(Text("Close role members"))
                    .ignoresSafeArea()

                    card(for: request, container: proxy.size)
                }
            }
            .animation(motion.panel, value: model.roleMembersRequest)
        }
    }

    private func card(for request: RoleMembersRequest, container: CGSize) -> some View {
        // Read here, so a member record landing redraws the list.
        let roster = model.roleRoster(for: request)
        let count = model.roleMemberCounts[request.guildID]?[request.roleID]
        let shown = roster.members.count
        let hidden = max(0, (count ?? shown) - shown)
        let listHeight = RosterLayout.headerHeight + CGFloat(shown) * RosterLayout.memberHeight
        let height = min(listHeight + (hidden > 0 ? Self.moreHeight : 0), Self.maximumHeight)
        let placement = ProfileCardPlacement(
            anchor: request.anchor,
            cardWidth: Self.width,
            overhang: EdgeInsets(),
            container: container
        )
        return VStack(spacing: 0) {
            MemberListView(
                roster: roster,
                presentationRevision: presentation.value,
                openProfile: { userID, frame in model.openProfile(userID, anchor: frame) },
                openMenu: { userID, frame in model.openUserMenu(for: userID, anchor: frame) },
                profiledUserID: model.profileRequest?.userID,
                isCovered: model.isCovered(.roleMembers)
            )
            // Discord's "+N more" under the hundred it lists.
            if hidden > 0 {
                Text("+\(hidden.formatted()) more")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.moreHeight, alignment: .leading)
                    .padding(.horizontal, Spacing.snug)
            }
        }
        .frame(width: Self.width, height: height)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(Palette.hairline)
        }
        .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .alignmentGuide(.leading) { _ in -placement.cardX }
        .alignmentGuide(.top) { _ in -placement.cardY(forHeight: height) }
        .transition(.materialize(from: placement.growthAnchor))
    }

    private static let moreHeight: CGFloat = 36
}
