import AppKit
import SwiftUI
import WingcordCore

/// Discord's Add Friend popout (`eF`, `eN`, `763349`), from the member list's head:
/// the form, a link to copy, and the requests already out there.
struct AddFriendFlyout: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isCopyingLink = false
    /// What Copy Friend Link just did, in Discord's words.
    @State private var linkOutcome: String?
    @State private var showsOutgoing = false

    private static let width: CGFloat = 320

    var body: some View {
        let requests = model.friendRequests
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.base) {
                Text("Add Friend")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 0)
                if let linkOutcome {
                    Text(linkOutcome)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .transition(.opacity)
                }
                copyLinkButton
            }
            .padding(.bottom, Spacing.snug)

            AddFriendForm()

            if !requests.isEmpty {
                Divider().padding(.vertical, Spacing.snug)
                requestList(requests)
            }
        }
        .padding(Spacing.margin)
        .frame(width: Self.width)
        .animation(motion.standard, value: linkOutcome)
        .animation(motion.standard, value: showsOutgoing)
        .appColorScheme()
    }

    private var copyLinkButton: some View {
        Button {
            copyLink()
        } label: {
            Group {
                if isCopyingLink {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(InkColor.solid)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(isCopyingLink)
        .help("Copy friend link")
        .accessibilityLabel(Text("Copy friend link"))
    }

    private func copyLink() {
        isCopyingLink = true
        Task {
            defer { isCopyingLink = false }
            do {
                let link = try await model.sessionController.createFriendLink()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                linkOutcome = "Friend link copied"
            } catch {
                linkOutcome = "Oops, something went wrong..."
            }
        }
    }

    @ViewBuilder
    private func requestList(_ requests: [FriendRequest]) -> some View {
        let incoming = requests.filter(\.isIncoming)
        let outgoing = requests.filter { !$0.isIncoming }
        HStack(spacing: Spacing.base) {
            Text("Friend Requests")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.secondary)
            if !incoming.isEmpty {
                Text(incoming.count.formatted())
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Palette.unreadBadge, in: .capsule)
            }
            Spacer(minLength: 0)
            Button {
                SettingsWindow.request(.privacySafety)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Friend request permissions")
            .accessibilityLabel(Text("Friend request permissions"))
        }
        .padding(.bottom, Spacing.tight)

        ScrollView {
            VStack(spacing: Spacing.tight) {
                if !outgoing.isEmpty {
                    // Discord's nested popout: a popover can't hang off a popover
                    // here, so it opens in place.
                    Button {
                        showsOutgoing.toggle()
                    } label: {
                        HStack(spacing: Spacing.base) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Ink.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Your Requests")
                                    .font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(Ink.primary)
                                Text("\(outgoing.count.formatted()) pending")
                                    .font(.system(.caption))
                                    .foregroundStyle(Ink.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: showsOutgoing ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Ink.secondary)
                        }
                        .padding(.horizontal, Spacing.snug)
                        .padding(.vertical, Spacing.base)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if showsOutgoing {
                        ForEach(outgoing) { FriendRequestRow(request: $0) }
                    }
                }
                ForEach(incoming) { FriendRequestRow(request: $0) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Its content's height up to the cap, so a note opening grows the flyout
        // rather than sliding out of a window that stayed the same size.
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
    }
}
