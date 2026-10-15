import SwiftUI
import WingcordCore

/// The detail column's top row, level with the traffic lights.
///
/// Three groups at most, as the HIG asks of a toolbar: the sidebar's controls
/// while the sidebar is away (they live in the panel otherwise), the title in
/// the middle, and the channel's acts with search at the trailing end. Every
/// one of them is also a menu-bar command.
struct DetailHeader: View {
    var layout: ShellLayout

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        let chrome = model.channelChrome
        let primary = model.workspacePresentation.primary
        HeaderBarLayout {
            leading
            TitleCapsule(title: model.headerTitle, chrome: chrome)
            trailing(chrome: chrome, primary: primary)
        }
        .padding(.leading, layout.detailHeaderLeadingClearance + Spacing.snug)
        .padding(.trailing, Spacing.snug)
        .frame(height: ShellMetrics.headerHeight)
        .dragsWindow()
        .background(alignment: .top) { HeaderShade() }
    }

    // MARK: Leading

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: Spacing.base) {
            if !layout.isSidebarShown {
                HeaderCircleButton(systemImage: "sidebar.leading", label: "Show Sidebar") {
                    ShellActions.toggleSidebar()
                }
                CreateMenu()
            }
        }
        .transition(.materialize(from: .leading, blurring: false))
    }

    // MARK: Trailing

    @ViewBuilder
    private func trailing(chrome: ChannelChrome, primary: WorkspacePresentation.Primary) -> some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                if chrome.canStartCall || chrome.canShowVoiceChat {
                    HeaderControlGroup { callControls(chrome) }
                }
                if hasChannelTools(chrome) || !primary.isServerPage {
                    HeaderControlGroup { channelTools(chrome, isServerPage: primary.isServerPage) }
                }
                if !primary.isServerPage && !primary.isCall && !primary.isHomePage {
                    HeaderSearch()
                }
            }
        }
    }

    private func hasChannelTools(_ chrome: ChannelChrome) -> Bool {
        chrome.canShowThreads || chrome.threadID != nil || chrome.canShowPins
            || chrome.canShowMemberList || chrome.canShowUserProfile || chrome.canShowSummaries
    }

    @ViewBuilder
    private func callControls(_ chrome: ChannelChrome) -> some View {
        if chrome.canStartCall {
            let title = chrome.isInCall ? "Leave the Call" : (chrome.isCallOngoing ? "Join the Call" : "Start a Call")
            let symbol = chrome.isInCall ? "phone.down.fill" : (chrome.isCallOngoing ? "phone.connection.fill" : "phone.fill")
            HeaderGroupButton(
                systemImage: symbol,
                label: title,
                tint: chrome.isInCall ? Palette.destructive : nil
            ) {
                toggleCall(chrome)
            }
        } else if chrome.canShowVoiceChat {
            HeaderGroupButton(
                systemImage: "bubble.left.and.text.bubble.right",
                label: chrome.isVoiceChatShown ? "Hide Chat" : "Show Chat",
                isActive: chrome.isVoiceChatShown
            ) {
                model.isVoiceChatShown.toggle()
            }
        }
    }

    @ViewBuilder
    private func channelTools(_ chrome: ChannelChrome, isServerPage: Bool) -> some View {
        if chrome.canShowThreads {
            HeaderGroupButton(systemImage: "number.square", label: "Threads", isActive: chrome.areThreadsShown) {
                guard let channelID = model.selectedChannelID else { return }
                if model.openThreadsChannelID == channelID {
                    model.closeThreadBrowser()
                } else {
                    model.openThreadBrowser(channelID)
                }
            }
            .popover(isPresented: Binding(
                get: { chrome.areThreadsShown },
                set: { if !$0, chrome.areThreadsShown { model.closeThreadBrowser() } }
            ), arrowEdge: .bottom) {
                if let channelID = model.openThreadsChannelID {
                    ThreadBrowserPane(channelID: channelID)
                }
            }
        }
        if let threadID = chrome.threadID {
            ThreadMoreButton(threadID: threadID, place: .page) {
                Image(systemName: "ellipsis")
                    .font(.system(size: ShellMetrics.headerGlyph, weight: .medium))
                    .foregroundStyle(InkColor.solid)
                    .frame(width: ShellMetrics.headerControl - 4, height: ShellMetrics.headerControl - 6)
                    .contentShape(.capsule)
            }
            .help("More")
        }
        if chrome.canShowPins {
            HeaderGroupButton(systemImage: "pin", label: "Pinned Messages", isActive: chrome.arePinsShown) {
                guard let channelID = model.selectedChannelID else { return }
                model.togglePinsPane(for: channelID)
            }
            .popover(isPresented: Binding(
                get: { chrome.arePinsShown },
                set: { if !$0, chrome.arePinsShown, let id = model.openPinsChannelID { model.togglePinsPane(for: id) } }
            ), arrowEdge: .bottom) {
                if let channelID = model.openPinsChannelID {
                    PinnedMessagesPane(channelID: channelID)
                }
            }
        }
        if chrome.canShowSummaries {
            HeaderGroupButton(
                systemImage: chrome.areSummariesShown ? "scroll.fill" : "scroll",
                label: chrome.areSummariesShown ? "Hide Summaries" : "Show Summaries",
                isActive: chrome.areSummariesShown
            ) {
                AppSettings.shared.showsSummaryBar.toggle()
            }
        }
        if !isServerPage {
            HeaderGroupButton(systemImage: "tray", label: "Inbox", isActive: model.isInboxShown) {
                model.toggleInbox()
            }
            .popover(isPresented: Binding(
                get: { model.isInboxShown },
                set: { if !$0, model.isInboxShown { model.toggleInbox() } }
            ), arrowEdge: .bottom) {
                InboxFlyout()
            }
        }
        if chrome.canShowMemberList {
            HeaderGroupButton(
                systemImage: "person.2.fill",
                label: chrome.isMemberListShown ? "Hide Members" : "Show Members",
                isActive: chrome.isMemberListShown
            ) {
                model.isMemberListShown.toggle()
            }
        } else if chrome.canShowUserProfile {
            HeaderGroupButton(
                systemImage: "person.crop.circle",
                label: chrome.isUserProfileShown ? "Hide User Profile" : "Show User Profile",
                isActive: chrome.isUserProfileShown
            ) {
                model.isDirectMessageProfileShown.toggle()
            }
        }
    }

    private func toggleCall(_ chrome: ChannelChrome) {
        guard let channelID = model.selectedChannelID else { return }
        if model.connectedVoiceChannelID == channelID {
            model.leaveVoice()
        } else if chrome.isCallOngoing {
            // Already running: join it, and ring nobody.
            model.joinCall(in: channelID)
        } else {
            model.startCall(in: channelID)
        }
    }
}

// MARK: - Layout

/// Leading, centre, trailing: the centre slot is centred in the whole row while
/// it fits there, and slides between its neighbours when it does not — so a
/// title never sits on top of a control.
struct HeaderBarLayout: Layout {
    var spacing: CGFloat = Spacing.base

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 600, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(leading)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(trailing)
        )
        let lower = bounds.minX + leading.width + (leading.width > 0 ? spacing : 0)
        let upper = bounds.maxX - trailing.width - (trailing.width > 0 ? spacing : 0)
        let available = max(0, upper - lower)
        let ideal = subviews[1].sizeThatFits(ProposedViewSize(width: available, height: bounds.height))
        let width = min(ideal.width, available)
        let x = min(max(bounds.midX - width / 2, lower), upper - width)
        subviews[1].place(
            at: CGPoint(x: x, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: width, height: ideal.height)
        )
    }
}

// MARK: - The title

/// Who or what the column shows, in a glass capsule centred over it — the way
/// Messages heads a conversation with its contact. The channel's acts hang off
/// it as a menu.
private struct TitleCapsule: View {
    var title: HeaderTitle
    var chrome: ChannelChrome

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        if !title.isEmpty {
            Menu {
                ChannelTitleMenu(chrome: chrome, model: model)
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(height: ShellMetrics.headerControl)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .animation(motion.glassMorph, value: title.name)
            .help(title.subtitle.isEmpty ? title.name : "\(title.name) — \(title.subtitle)")
            .accessibilityLabel(Text(title.name))
        }
    }

    private var label: some View {
        HStack(spacing: Spacing.base) {
            face
            VStack(alignment: .leading, spacing: 0) {
                Text(title.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .lineLimit(1)
                if !title.subtitle.isEmpty {
                    Text(title.subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(.leading, title.symbolName == nil ? 6 : 12)
        .padding(.trailing, 14)
    }

    @ViewBuilder
    private var face: some View {
        if let symbolName = title.symbolName {
            Image(symbol: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.secondary)
        } else {
            AvatarView(
                url: title.avatarURL,
                monogram: title.monogram ?? "?",
                side: ShellMetrics.titleAvatar
            )
            .overlay(alignment: .bottomTrailing) {
                if let status = title.status {
                    PresenceDot(status: status, side: 8).offset(x: 1, y: 1)
                }
            }
        }
    }
}

// MARK: - Shade

/// The soft band behind the header, so its glass reads against a quiet field
/// rather than whatever the wallpaper or the transcript has under it —
/// Noodle's header shade, drawn behind the controls and in front of the ground.
private struct HeaderShade: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.06), location: 0),
                .init(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.03), location: 0.55),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: ShellMetrics.headerHeight + 18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
