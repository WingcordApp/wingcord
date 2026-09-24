import SwiftUI

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
    /// The topic flyout's contents. A closure for the reason `pinsContent` is
    /// one: the bar is evaluated on every navigation and the flyout is opened a
    /// few times a session.
    var topicContent: () -> AnyView = { AnyView(EmptyView()) }
    var toggleCall: () -> Void = {}
    var toggleVoiceChat: () -> Void = {}
    var togglePins: () -> Void = {}
    /// The pins popover's contents. A closure rather than the pane itself, so
    /// the toolbar never builds it for a channel nobody has opened it in — a
    /// popover's content closure is only called when it is presented, and this
    /// keeps the store read out of the toolbar's own body.
    var pinsContent: () -> AnyView = { AnyView(EmptyView()) }
    var toggleThreads: () -> Void = {}
    /// The Threads popover's contents, for the reason `pinsContent` is a
    /// closure: it is opened a few times a session and the bar is evaluated on
    /// every navigation.
    var threadsContent: () -> AnyView = { AnyView(EmptyView()) }
    var toggleSummaries: () -> Void = {}

    // MARK: The inbox
    //
    // **Not on `chrome`, and that is the point.** Every other control in this
    // bar is about the channel the reader is standing in, and `ChannelChrome`
    // is what resolves that. The inbox is about the account: it is the same
    // control in every channel, on a server page, and with nothing selected at
    // all. Putting it on the chrome would tie a global surface to a per-channel
    // projection and make it vanish wherever that projection is `.none`.
    //
    // **Deliberately unbadged.** Discord does not badge it either, and the
    // reason here is mechanical: a count would have to be summed over
    // `readStates`, which would make this bar — evaluated on every navigation —
    // depend on a table every inbound message writes. The counts live on the
    // rail and on each group's own header, where they already are.
    var isInboxShown: Bool = false
    var toggleInbox: () -> Void = {}
    /// The flyout's contents. A closure for the reason `pinsContent` is one:
    /// the bar is evaluated on every navigation and the panel is opened a few
    /// times a session, so a store read here would run constantly.
    var inboxContent: () -> AnyView = { AnyView(EmptyView()) }

    private var callTitle: String {
        if chrome.isInCall { return "Leave the Call" }
        return chrome.isCallOngoing ? "Join the Call" : "Start a Call"
    }

    private var callSymbol: String {
        if chrome.isInCall { return "phone.down.fill" }
        // A phone with its connection arcs for a call already in progress,
        // against the plain handset for one that does not exist yet: the two
        // acts have to be told apart at a glance, because only one of them
        // rings somebody.
        return chrome.isCallOngoing ? "phone.connection.fill" : "phone.fill"
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // Named rather than tested for a channel id: a server page has no
            // channel and still has a title, and an item that disappears there
            // is a hole the bar closes by sliding its neighbours.
            if !chrome.name.isEmpty {
                ChannelPill(
                    name: chrome.name,
                    symbolName: chrome.symbolName,
                    canOpenTopic: !(chrome.topic?.isEmpty ?? true),
                    isTopicShown: chrome.isTopicShown,
                    action: openChannelDetails,
                    topicContent: topicContent
                )
            }
        }

        // Without a spacer the trailing item packs against the navigation
        // items, so the member toggle sat beside the channel pill at the
        // leading edge instead of at the far end of the bar.
        ToolbarSpacer(.flexible)

        // **One control, two states.** Starting a call and hanging one up are
        // one bit resolved two ways — §5.5 — and declaring two items would leave
        // a hole in the bar in whichever state is not showing, which the bar
        // closes by sliding its neighbours.
        ToolbarItem(placement: .primaryAction) {
            if chrome.canStartCall {
                // **One control, three states**, because the third one is a
                // different act: joining a call that is already running must
                // not ring the person sitting in it, and offering to "start"
                // one that exists is how a call became unrejoinable.
                Button(action: toggleCall) {
                    Label(callTitle, systemImage: callSymbol)
                }
                .help(callTitle)
                .tint(chrome.isInCall ? Palette.destructive : nil)
            } else if chrome.canShowVoiceChat {
                Button(action: toggleVoiceChat) {
                    Label(
                        chrome.isVoiceChatShown ? "Hide the Chat" : "Show the Chat",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
                .help(chrome.isVoiceChatShown ? "Hide the chat" : "Show the chat")
            }
        }

        // **The one presentation attached inline in this app, and the exception
        // is scoped.** §2 forbids a presentation modifier on a list ROW, because
        // it is evaluated as part of every row's body on every pass. This is one
        // toolbar item, evaluated once, and it is the only place a popover can
        // point at the control that opened it — the alternative is a
        // window-root presenter anchored to a rect the toolbar cannot report.
        // Beside the pins and under the same scoped exception — one toolbar
        // item, evaluated once, pointing its popover at the control that opened
        // it.
        ToolbarItem(placement: .primaryAction) {
            if chrome.canShowThreads {
                Button(action: toggleThreads) {
                    Label("Threads", systemImage: "bubble.left.and.bubble.right")
                }
                .help("Threads")
                .popover(isPresented: threadsBinding, arrowEdge: .bottom) {
                    threadsContent()
                }
            }
        }

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

        // Discord's own words, and its own condition: only where the channel
        // has summaries, so the item is a hole everywhere else — the bar it
        // hides does not exist there either.
        ToolbarItem(placement: .primaryAction) {
            if chrome.canShowSummaries {
                Button(action: toggleSummaries) {
                    Label(
                        chrome.areSummariesShown ? "Hide Summaries" : "Show Summaries",
                        systemImage: chrome.areSummariesShown ? "scroll.fill" : "scroll"
                    )
                }
                .help(chrome.areSummariesShown ? "Hide Summaries" : "Show Summaries")
            }
        }

        // **Its own group, because it is not about this channel.** A spacer
        // between toolbar items breaks the glass platter they share, which is
        // how a Liquid Glass bar says "these belong together and that one does
        // not" — and every item before this one is scoped to the channel while
        // the inbox is scoped to the account.
        ToolbarSpacer(.fixed)

        // The third and last inline presentation in this app, under the same
        // scoped exception the pins and threads panes take: one toolbar item,
        // evaluated once, pointing its popover at the control that opened it.
        ToolbarItem(placement: .primaryAction) {
            Button(action: toggleInbox) {
                Label("Inbox", systemImage: "tray")
            }
            .help("Inbox")
            .popover(isPresented: inboxBinding, arrowEdge: .bottom) {
                inboxContent()
            }
        }
    }

    /// Same rule as `pinsBinding`: the setter may only clear when the store is
    /// still showing it, so a dismissal arriving while something else is
    /// opening cannot take the new one down with it.
    private var inboxBinding: Binding<Bool> {
        Binding(
            get: { isInboxShown },
            set: { if !$0, isInboxShown { toggleInbox() } }
        )
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

    /// Same rule as `pinsBinding`: the setter may only clear when the store is
    /// still showing this one.
    private var threadsBinding: Binding<Bool> {
        Binding(
            get: { chrome.areThreadsShown },
            set: { if !$0, chrome.areThreadsShown { toggleThreads() } }
        )
    }
}
