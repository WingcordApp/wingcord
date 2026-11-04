import SwiftUI
import WingcordCore

/// The friend requests, behind the inbox's own control.
///
/// **Nothing here is fetched.** Relationships arrive whole on READY and are kept
/// current by `RELATIONSHIP_ADD` / `RELATIONSHIP_REMOVE`, so this pane is a
/// projection of tables the client already holds — it opens filled, with no
/// spinner and no route. What *was* missing is the ordering: Discord sends
/// `since` on every relationship and this client decoded four fields of the
/// object and not that one, so the list had nothing to sort by but the user id,
/// which sorts by when each account was made. See `RelationshipFacts`.
///
/// **Incoming and outgoing in one list, incoming first.** Only one of the two is
/// a question addressed to the reader; sorting them together by date would bury
/// an answer somebody is waiting for underneath the reader's own sent requests.
struct FriendRequestsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let requests = model.friendRequests
        Group {
            if requests.isEmpty {
                VStack(spacing: Spacing.base) {
                    Image(systemName: "person.2")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Ink.tertiary)
                        .padding(.bottom, Spacing.tight)
                        .accessibilityHidden(true)
                    Text("No pending requests")
                        .font(.system(.headline))
                        .foregroundStyle(Ink.primary)
                    Text("Friend requests you send and receive both show up here.")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Spacing.group)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.tight) {
                        ForEach(requests) { request in
                            FriendRequestRow(request: request)
                        }
                    }
                    .padding(Spacing.snug)
                }
                .scrollBounceBehavior(.basedOnSize)
                .softScrollEdgesVertical()
            }
        }
    }
}

/// One request, and the two answers to it.
struct FriendRequestRow: View {
    var request: FriendRequest

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var shape: RoundedRectangle { .rect(cornerRadius: Radius.chip) }

    var body: some View {
        let user = model.users[request.id]
        let isBusy = model.relationshipsInFlight.contains(request.id)

        HStack(spacing: Spacing.snug) {
            AvatarView(
                url: user.flatMap { model.avatarURL(for: $0, side: Metrics.avatarMessage) },
                monogram: user?.monogram ?? "?",
                side: Metrics.avatarMessage
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(user?.displayName ?? "Unknown")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                HStack(spacing: Spacing.tight + 1) {
                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                    // **Discord's own flags, and they are two different
                    // things.** A stranger request is ordinary — somebody who
                    // found the reader by username — and is marked so it can be
                    // weighed, not so it can be hidden. Spam is Discord's
                    // judgement and earns the warning colour.
                    if request.facts.isSpam {
                        FlagChip(text: "Spam", tint: Palette.unreadBadge)
                    } else if request.facts.isStranger {
                        FlagChip(text: "Stranger", tint: Palette.mutedBadge)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                answers
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .background(isHovering ? Palette.hoverFill : .clear, in: shape)
        .animation(motion.hover, value: isHovering)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(user?.displayName ?? "Unknown"), \(subtitle)")
    }

    /// **Accept is only offered on an incoming request.** An outgoing one has a
    /// single answer — withdraw it — and drawing a tick beside it would offer
    /// to accept a request the reader themselves sent.
    @ViewBuilder
    private var answers: some View {
        HStack(spacing: Spacing.tight + 2) {
            if request.isIncoming {
                Button {
                    model.answerFriendRequest(request.id, accept: true)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                        .font(.system(.subheadline, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Palette.affirmative)
                .help("Accept")
            }
            Button {
                model.answerFriendRequest(request.id, accept: false)
            } label: {
                Label(
                    request.isIncoming ? "Ignore" : "Cancel",
                    systemImage: "xmark"
                )
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .help(request.isIncoming ? "Ignore this request" : "Cancel this request")
        }
    }

    private var subtitle: String {
        let direction = request.isIncoming ? "Incoming" : "Sent"
        guard let since = request.facts.since else { return direction }
        return "\(direction) · \(PresentationRevision.shared.timeline.dayLabel(since, calendar: .current))"
    }
}

/// A small tinted word beside a name — Discord's flags on a request.
struct FlagChip: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(.caption2, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.tight + 1)
            .padding(.vertical, 1)
            .background(tint, in: .capsule)
    }
}
