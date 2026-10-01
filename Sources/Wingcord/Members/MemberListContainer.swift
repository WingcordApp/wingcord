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
            isCovered: model.isWindowCovered,
            activity: model.memberActivityBlock,
            openActivity: { id, frame in model.openActivityCard(id, anchor: frame) },
            toggleActivity: { model.toggleActivitySection() },
            activityMenu: { frame in model.activityMenuAnchor = frame },
            noteActivityShown: { model.noteActivityCardsShown($0) }
        )
        // The feed's authors this server has not sent, so the section can
        // tell who here may see the channel.
        .task(id: ActivityAuthorsKey(guildID: model.selectedGuildID, feed: model.activityFeed.inbox?.refreshToken)) {
            guard let guildID = model.selectedGuildID else { return }
            model.sessionController.requestActivityAuthors(inGuild: guildID)
        }
        // The window coming forward asks again when the feed has expired —
        // Discord's `WINDOW_FOCUS`.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.sessionController.loadActivityFeedIfDue()
        }
    }
}

private struct ActivityAuthorsKey: Hashable {
    var guildID: GuildID?
    var feed: String?
}
