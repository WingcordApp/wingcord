import SwiftUI
import WingcordCore

/// One application's own page, as a sheet.
///
/// **The third surface `ActivityDetailPage` is drawn on, and the first that is
/// a sheet.** The other two are the activity launcher's flyout and discovery's
/// detail column; this one is opened from a recent-activity row *inside* the
/// full profile, which is itself a layer over the window. A popover pointing
/// at a row in there would be a window pointing into a window — and §1 records
/// that no presentation on macOS gives a transparent margin to hang one in.
///
/// It draws the `.page` shape rather than the flyout's, because a sheet has a
/// column's worth of width and the flyout's 388-point measure would leave the
/// hero stranded in the middle of it.
struct ActivityInfoSheet: View {
    var applicationID: ApplicationID

    @Environment(AppModel.self) private var model

    var body: some View {
        ActivityDetailPage(
            applicationID: applicationID,
            // The conversation the reader came from, so Play and the commands
            // have somewhere to act. Nil is a real state — a profile opened
            // from the rail — and the page already draws itself as a
            // description when it has no channel.
            channelID: model.selectedChannelID,
            layout: .page,
            onBack: { model.activityInfoID = nil },
            onLaunched: { model.activityInfoID = nil },
            onOpenSimilar: { model.activityInfoID = $0 }
        )
        .frame(minWidth: 460, minHeight: 520)
        .readingSurface()
        .overlay(alignment: .topTrailing) {
            ModalCloseButton { model.activityInfoID = nil }
                .padding(Spacing.margin)
        }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsActivityInfo() -> some View {
        modifier(ActivityInfoPresenter())
    }
}

private struct ActivityInfoPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        // **`isPresented`, not `item`.** A `Snowflake` is `Hashable` and
        // deliberately not `Identifiable` — an id is not a *thing with* an id
        // — so the binding is the presence of one.
        return content.modal(
            isPresented: Binding(
                get: { model.activityInfoID != nil },
                set: { if !$0 { model.activityInfoID = nil } }
            ),
            style: .panel
        ) {
            if let id = model.activityInfoID {
                ActivityInfoSheet(applicationID: id)
                    .environment(model)
            }
        }
    }
}
