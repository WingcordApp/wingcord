import SwiftUI
import WingcordCore

/// What somebody is doing, when they are doing anything.
///
/// **Lifted out of the old two-column profile when that surface was replaced.**
/// It was the only part of it worth keeping: the tabs, the panes and the empty
/// states all existed to work around a 340-point column, and the column is gone.
struct ActivityCard: View {
    var activity: Activity
    var ground: ProfileGround

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(.title3))
                .foregroundStyle(ground.accent ?? InkColor.secondary)
                .frame(width: 40, height: 40)
                .background(ground.panelFill, in: .rect(cornerRadius: Radius.row))

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                if let details = activity.details, !details.isEmpty {
                    Text(details)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(2)
                }
                if let state = activity.state, !state.isEmpty {
                    Text(state)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **No plate of its own.** This used to be a solid panel on the old
        // profile's ground; inside a slab it is a second opaque box drawn on top
        // of glass, which is the dark rectangle that appeared in the middle of
        // the Activity pane. The slab is the surface — this is its content.
    }

}
