import SwiftUI
import WingcordCore

/// Reads the store and hands the member list its sections.
struct MemberListContainer: View {
    /// The window's chrome above this column, measured by the pane that owns it.
    var topInset: CGFloat = 0

    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared

    var body: some View {
        MemberListView(
            roster: model.roster,
            presentationRevision: presentation.value,
            topInset: topInset,
            openProfile: { userID, frame in
                model.openProfile(userID, anchor: frame)
            },
            openMenu: { userID, frame in
                model.openUserMenu(for: userID, anchor: frame)
            },
            showRows: { rows, margin in
                model.sessionController.showMemberListRows(rows, margin: margin)
            },
            // A card open over the roster keeps its own subject's plate
            // moving, whether or not the pointer is still on the row — the
            // card is what the pointer is on.
            profiledUserID: model.profileRequest?.userID,
            // A tracking area is not occlusion-tested, so without this the
            // roster lights rows under an open card. The profiled row keeps its
            // plate moving regardless — `platedRow` prefers the card's subject
            // over the pointer's.
            isCovered: model.isWindowCovered
        )
    }
}
