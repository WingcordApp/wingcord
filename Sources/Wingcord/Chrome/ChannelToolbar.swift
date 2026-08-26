import SwiftUI
import WingcordCore

/// The window's one row of chrome.
///
/// **Everything here is a real `ToolbarItem`, and that is the whole point.** A
/// hand-drawn band overlaid inside the detail column produces four separate
/// faults that cannot be fixed inside the band: a blank strip above it where the
/// real toolbar still is; `.glass` controls that resolve against the scrolling
/// transcript instead of the toolbar's material; no scroll-edge blur, because
/// the effect needs a registered *bar*; and traffic-light collisions that have
/// to be cleared by hand whenever the sidebar collapses.
///
/// The sidebar toggle is not here because the split view installs its own, at
/// the system's size and with the system's glass. Adding a second one is how an
/// app ends up with two toggles that disagree.
struct ChannelToolbar: ToolbarContent {
    var chrome: ChannelChrome
    var toggleMemberList: () -> Void = {}
    var openChannelDetails: () -> Void = {}

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if chrome.channelID != nil {
                ChannelPill(
                    name: chrome.name,
                    kind: chrome.kind,
                    action: openChannelDetails
                )
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if chrome.canShowMemberList {
                Button(action: toggleMemberList) {
                    Label(
                        chrome.isMemberListShown ? "Hide Members" : "Show Members",
                        systemImage: "person.2.fill"
                    )
                }
                .help(chrome.isMemberListShown ? "Hide member list" : "Show member list")
            }
        }
    }
}
