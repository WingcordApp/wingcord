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
    var togglePins: () -> Void = {}
    /// The pins popover's contents. A closure rather than the pane itself, so
    /// the toolbar never builds it for a channel nobody has opened it in — a
    /// popover's content closure is only called when it is presented, and this
    /// keeps the store read out of the toolbar's own body.
    var pinsContent: () -> AnyView = { AnyView(EmptyView()) }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // Named rather than tested for a channel id: a server page has no
            // channel and still has a title, and an item that disappears there
            // is a hole the bar closes by sliding its neighbours.
            if !chrome.name.isEmpty {
                ChannelPill(
                    name: chrome.name,
                    symbolName: chrome.symbolName,
                    action: openChannelDetails
                )
            }
        }

        // Without a spacer the trailing item packs against the navigation
        // items, so the member toggle sat beside the channel pill at the
        // leading edge instead of at the far end of the bar.
        ToolbarSpacer(.flexible)

        // **The one presentation attached inline in this app, and the exception
        // is scoped.** §2 forbids a presentation modifier on a list ROW, because
        // it is evaluated as part of every row's body on every pass. This is one
        // toolbar item, evaluated once, and it is the only place a popover can
        // point at the control that opened it — the alternative is a
        // window-root presenter anchored to a rect the toolbar cannot report.
        ToolbarItem(placement: .primaryAction) {
            if chrome.canShowPins {
                Button(action: togglePins) {
                    Label("Pinned Messages", systemImage: "pin")
                }
                .help("Pinned messages")
                .popover(isPresented: pinsBinding, arrowEdge: .bottom) {
                    pinsContent()
                }
            }
        }

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

    /// **The setter may only clear when the store is still showing this one.**
    /// Clearing unconditionally lets a dismissal that arrives while a second
    /// channel's pane is opening take the new one down with it.
    private var pinsBinding: Binding<Bool> {
        Binding(
            get: { chrome.arePinsShown },
            set: { if !$0, chrome.arePinsShown { togglePins() } }
        )
    }
}
