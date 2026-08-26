import SwiftUI
import WingcordCore

/// Reads the store and hands the member list its sections.
struct MemberListContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MemberListView(
            sections: model.rosterSections,
            openProfile: { userID, frame in
                model.profileRequest = ProfileRequest(userID: userID, anchor: frame)
            }
        )
    }
}
