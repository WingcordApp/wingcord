import SwiftUI
import WingcordCore

/// Reads the store and hands the member list its sections.
struct MemberListContainer: View {
    /// The window's chrome above this column, measured by the pane that owns it.
    var topInset: CGFloat = 0
    /// What the list is being searched for, or nil while it isn't.
    var search: String?

    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared
    @State private var hover: MemberRowHover?
    @State private var isPointerOnActions = false
    @State private var voiceButtons: [MemberVoiceButton] = []

    /// The row that stays lit, whatever the pointer does: Discord's `.active`.
    private var pinnedUserID: UserID? {
        model.profileRequest?.userID
            ?? model.userMenu?.userID
            ?? (isPointerOnActions ? hover?.userID : nil)
    }

    /// The words being looked for: nothing typed yet is the whole list.
    private var query: String {
        (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let searchRoster = query.isEmpty ? nil : model.memberSearchRoster(query: query)
        MemberListView(
            roster: searchRoster ?? model.roster,
            presentationRevision: presentation.value,
            topInset: topInset,
            openProfile: { userID, frame in
                model.openProfile(userID, anchor: frame)
            },
            openMenu: { userID, frame in
                model.openUserMenu(for: userID, anchor: frame)
            },
            showRows: { runs, margin in
                model.sessionController.showMemberListRows(runs, margin: margin)
            },
            toggleSection: { model.toggleMemberSection($0) },
            noteHover: { hover = $0 },
            noteVoiceButtons: { voiceButtons = $0 },
            openRoom: { model.openChannelFromSurface($0) },
            pinnedUserID: pinnedUserID,
            needApplications: { model.resolveApplications($0) },
            // A card open over the roster keeps its own subject's plate
            // moving, whether or not the pointer is still on the row — the
            // card is what the pointer is on.
            profiledUserID: model.profileRequest?.userID,
            // A tracking area is not occlusion-tested, so without this the
            // roster lights rows under an open card. The profiled row keeps its
            // plate moving regardless — `platedRow` prefers the card's subject
            // over the pointer's.
            isCovered: model.isWindowCovered,
            // Nothing above the answers to a search.
            activity: searchRoster == nil ? model.memberActivityBlock : nil,
            openActivity: { id, frame in model.openActivityCard(id, anchor: frame) },
            toggleActivity: { model.toggleActivitySection() },
            activityMenu: { frame in model.activityMenuAnchor = frame },
            noteActivityShown: { model.noteActivityCardsShown($0) }
        )
        // **Rows dissolve before they reach the strip and the head**, as the
        // transcript's do under its header (`INVARIANTS.md`): those float over the
        // list in clear glass, and a name passing behind a name doesn't read as
        // either. Just short of the first heading, whose words stay whole at rest.
        .mask { MemberListTopFade(clearHeight: max(0, topInset - 14)) }
        .overlay { MemberVoiceButtonsOverlay(buttons: voiceButtons) }
        .overlay { MemberRowActionsOverlay(hover: hover, isPointerOnActions: $isPointerOnActions) }
        .overlay(alignment: .top) {
            if searchRoster?.sections.isEmpty == true {
                Text("No members match that search.")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .padding(.top, topInset + Spacing.margin)
                    .allowsHitTesting(false)
            }
        }
        // Who else is out there by that name: Discord's own question for its
        // mentions, a beat after the typing stops. The answers land in the same
        // tables, and the roster above finds them there.
        .task(id: query) {
            guard !query.isEmpty, let guildID = model.selectedGuildID else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.sessionController.queryMembers(query, inGuild: guildID)
        }
        // Everyone in a room here that this session has no record of, so Active
        // Now can name them.
        .task(id: model.selectedGuildID.map { RoomPeopleKey(guildID: $0, inRooms: Set(model.voiceStates.values.compactMap { $0.guildID == model.selectedGuildID && $0.channelID != nil ? $0.userID : nil })) }) {
            guard let guildID = model.selectedGuildID else { return }
            model.sessionController.requestPeopleInRooms(inGuild: guildID)
        }
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

/// Clear all the way down the strip and the head, then whole a little past their foot.
///
/// **Not `TranscriptTopFade`**, whose ramp runs the whole way down from the window's
/// top: over a band this tall that leaves a tenth of a row showing through the strip.
private struct MemberListTopFade: View {
    var clearHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: clearHeight)
            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
            Color.white
        }
        .allowsHitTesting(false)
    }
}

private struct RoomPeopleKey: Hashable {
    var guildID: GuildID
    var inRooms: Set<UserID>
}

private struct ActivityAuthorsKey: Hashable {
    var guildID: GuildID?
    var feed: String?
}
