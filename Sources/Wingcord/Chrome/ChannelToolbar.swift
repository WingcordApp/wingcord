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
    var toggleUserProfile: () -> Void = {}
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

        // Without a spacer the trailing item packs against the navigation
        // items, so the member toggle sat beside the channel pill at the
        // leading edge instead of at the far end of the bar.
        ToolbarSpacer(.flexible)

        // **One item, two surfaces, and they are mutually exclusive.** A guild
        // channel has a roster and no single person; a direct message has a
        // person and no roster. Declaring two items would leave a hole in the
        // bar in both cases, and the bar closes holes by sliding its neighbours
        // — which moves the sidebar toggle every time the reader opens a DM.
        ToolbarItem(placement: .primaryAction) {
            if chrome.canShowMemberList {
                Button(action: toggleMemberList) {
                    Label(
                        chrome.isMemberListShown ? "Hide Members" : "Show Members",
                        systemImage: "person.2.fill"
                    )
                }
                .help(chrome.isMemberListShown ? "Hide member list" : "Show member list")
            } else if chrome.canShowUserProfile {
                Button(action: toggleUserProfile) {
                    Label(
                        chrome.isUserProfileShown ? "Hide User Profile" : "Show User Profile",
                        systemImage: "person.crop.circle"
                    )
                }
                .help(chrome.isUserProfileShown ? "Hide user profile" : "Show user profile")
            }
        }
    }
}
