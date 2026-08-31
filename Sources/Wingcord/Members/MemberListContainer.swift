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
            sections: model.rosterSections,
            presentationRevision: presentation.value,
            topInset: topInset,
            openProfile: { userID, frame in
                model.openProfile(userID, anchor: frame)
            },
            openMenu: { userID, frame in
                model.openUserMenu(for: userID, anchor: frame)
            }
        )
    }
}
