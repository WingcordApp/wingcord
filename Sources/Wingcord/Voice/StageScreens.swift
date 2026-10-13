import SwiftUI
import WingcordCore

// MARK: - A stage's three arrangements, and what sits over them
//
// Discord's stage (module 883396, `iA`) draws one of three things under its
// header: the start screen for a moderator while nothing is live, the room for
// somebody in it, and the join card for everybody else.

/// The line across the top of a stage — Discord's `to`: the topic, or the
/// channel's name while nothing is live; who is speaking and who is listening;
/// and, for whoever may answer them, Show Requests with its count.
struct StageHeader: View {
    var stage: StagePresentation
    /// Shown while the requests sidebar is closed — the sidebar has its own
    /// Close.
    var showsRequestsButton: Bool
    var showRequests: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "person.wave.2.fill")
                .foregroundStyle(stage.isLive ? Ink.tertiary : Ink.secondary)
                .accessibilityLabel(Text("Stage Channel"))
            Text(stage.topic ?? stage.channelName)
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Divider()
                .frame(height: 16)
            Label(StageCopy.speakingCount(stage.speakers.count), systemImage: "mic.fill")
            Label("\(stage.audience.count) in audience", systemImage: "person.2.fill")
            Spacer(minLength: 0)
            if showsRequestsButton {
                let waiting = stage.requests.count { !$0.isInvited }
                Button(action: showRequests) {
                    Label("Show Requests", systemImage: "hand.raised")
                        .overlay(alignment: .topTrailing) {
                            if waiting > 0 {
                                Text(waiting > 99 ? "99+" : "\(waiting)")
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .background(Palette.destructive, in: .capsule)
                                    .offset(x: 8, y: -6)
                            }
                        }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.system(.caption))
        .foregroundStyle(Ink.tertiary)
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
    }
}

/// Discord's "This Video Stage is maxed out." under the header, for a
/// moderator — with Dismiss. The upsell Discord shows instead in a smaller
/// server is not drawn: this client sells nothing.
struct StageCapacityNotice: View {
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: "video.badge.ellipsis")
                .font(.system(.title3))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("This Video Stage is maxed out.")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.primary)
                Text("This Stage is at maximum capacity.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: Spacing.base)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(Spacing.snug)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .padding(.horizontal, Spacing.margin)
    }
}

/// Discord's start screen (`il`), for a moderator while nothing is live:
/// what is about to start, Start the Stage, Create Event, Continue without
/// starting, and who is already waiting.
struct StageStartScreen: View {
    var stage: StagePresentation
    var waitingFaces: [StageMember]
    var act: (StageStartAct) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.group) {
                VStack(spacing: Spacing.base) {
                    Text("Waiting for the Stage to start")
                        .font(.system(.largeTitle, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text("What will you be talking about today?")
                        .font(.system(.title3))
                        .foregroundStyle(Ink.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(spacing: Spacing.snug) {
                    StageEventCards(events: stage.imminentEvents, act: act)
                    // `zU`: a teen where the gate applies is not offered it.
                    if !stage.isTeen {
                        StageOptionCard(
                            title: "Start the Stage",
                            detail: "Pick a topic to start the conversation.",
                            symbol: "person.wave.2.fill",
                            tint: Palette.presenceOnline
                        ) { act(.startStage) }
                    }
                    if stage.canCreateEvent {
                        StageOptionCard(
                            title: "Create Event",
                            detail: "Schedule a Stage for a future date.",
                            symbol: "calendar",
                            tint: Palette.accent
                        ) { act(.createEvent) }
                    }
                    StageOptionCard(
                        title: "Continue without starting",
                        detail: "For mic checks. Start when you\u{2019}re ready.",
                        symbol: "mic.fill",
                        tint: Color(white: 0.35)
                    ) { act(.continueWithoutStarting) }
                }
                .frame(maxWidth: 440)

                if let line = stage.waitingLine {
                    HStack(spacing: Spacing.base) {
                        HStack(spacing: -4) {
                            ForEach(waitingFaces.prefix(3)) { member in
                                AvatarView(url: member.avatarURL, monogram: member.monogram, side: 16)
                            }
                        }
                        .accessibilityHidden(true)
                        Text(line)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.secondary)
                    }
                }
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
    }
}

/// What the start screen's cards ask for.
enum StageStartAct {
    case startStage
    case createEvent
    case continueWithoutStarting
    /// An event about to start: its own start, or its details.
    case event(ScheduledEvent)
}

/// Discord's cards for the channel's events about to start (module 394412):
/// "Start Event: …" for whoever may run it, "Upcoming Event: …" otherwise,
/// and when.
struct StageEventCards: View {
    var events: [ScheduledEvent]
    var act: (StageStartAct) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let clock = EventClock.current()
        ForEach(events) { event in
            let canStart = model.canManage(event)
            StageOptionCard(
                title: canStart ? "Start Event: \u{201C}\(event.name)\u{201D}" : "Upcoming Event: \u{201C}\(event.name)\u{201D}",
                detail: "Scheduled for \(clock.startText(event.startsAt, now: .now))",
                symbol: "calendar",
                tint: Palette.presenceOnline
            ) { act(.event(event)) }
        }
    }
}

/// Discord's join card (`eQ`): up to five speakers' faces, the channel's
/// name, who is speaking, and Join Stage — Channel Locked without Connect —
/// with Invite beside it.
struct StageJoinCard: View {
    var stage: StagePresentation
    var join: () -> Void

    @State private var isInviteOpen = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.margin) {
                if !stage.speakers.isEmpty {
                    // Discord's `maxWidth: 168 * (4 faces ? 2 : 3)`: three to
                    // a row, two when there are exactly four.
                    let perRow = stage.speakers.count == 4 ? 2 : 3
                    let faces = Array(stage.speakers.prefix(5))
                    let columns = Array(repeating: GridItem(.fixed(56), spacing: Spacing.snug), count: min(perRow, faces.count))
                    LazyVGrid(columns: columns, spacing: Spacing.snug) {
                        ForEach(faces) { member in
                            AvatarView(url: member.avatarURL, monogram: member.monogram, side: 48)
                                .help(member.name)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(stage.channelName)
                    .font(.system(.largeTitle, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(stage.speakingLine)
                    .font(.system(.title3))
                    .foregroundStyle(Ink.secondary)
                HStack(spacing: Spacing.snug) {
                    Button(stage.canConnect ? "Join Stage" : "Channel Locked", action: join)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.presenceOnline)
                        .disabled(!stage.canConnect)
                    if stage.canInvite, let guildID = stage.guildID {
                        Button("Invite") { isInviteOpen = true }
                            .buttonStyle(.bordered)
                            .popover(isPresented: $isInviteOpen, arrowEdge: .bottom) {
                                ServerOptionsMenu(
                                    guildID: guildID,
                                    startsOn: .invite,
                                    inviteChannelID: stage.channelID
                                ) { isInviteOpen = false }
                            }
                    }
                }
                .controlSize(.large)
            }
            .multilineTextAlignment(.center)
            .padding(Spacing.section)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
    }
}
