import SwiftUI
import WingcordCore

/// Reads the store and hands the member list its sections.
struct MemberListContainer: View {
    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared

    var body: some View {
        MemberListView(
            sections: model.rosterSections,
            presentationRevision: presentation.value,
            openProfile: { userID, frame in
                model.openProfile(userID, anchor: frame)
            }
        )
    }
}
