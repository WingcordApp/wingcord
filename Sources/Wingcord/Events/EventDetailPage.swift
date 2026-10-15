import SwiftUI
import WingcordCore

/// One event — Discord's details modal (`640132`): the cover, Event Info and
/// "N Interested", the actions at the foot.
///
/// Event Info carries when, the server, where, how many are interested (which
/// turns to the other tab), who made it and the whole description, then a
/// series' dates. Choosing a date makes the page that date's: its time, its
/// count, its people and its answers.
struct EventDetailPage: View {
    var event: ScheduledEvent
    /// The date the page was opened on, for a series.
    var requested: UInt64?

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .info
    /// The date chosen from "Events in series", over the one opened on.
    @State private var chosen: UInt64?
    @State private var confirmation: EventConfirmation?

    enum Tab: Hashable { case info, interested }

    var body: some View {
        let occurrence = model.shownOccurrence(of: event, requested: chosen ?? requested)
        let count = model.interestedCount(for: event, at: occurrence)
        VStack(spacing: 0) {
            EventsPanelHeader(title: event.name) {
                Button { model.showEventsList() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(InkColor.solid)
                        .frame(width: Metrics.control, height: Metrics.control)
                        .background(Circle().fill(Palette.hoverFill))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("All Events")
                .accessibilityLabel(Text("All events"))
            } trailing: {
                EmptyView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let cover = event.imageHash.flatMap({ CDN.scheduledEventCover(eventID: event.id, hash: $0, side: 560) }) {
                        RemoteImage(url: cover, side: 560, bucket: .artwork) { Palette.hoverFill }
                            .aspectRatio(2.5, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .accessibilityHidden(true)
                    }
                    SegmentedPicker(
                        options: [
                            .init(Tab.info, "Event Info"),
                            .init(Tab.interested, "\((count ?? 0).formatted()) Interested"),
                        ],
                        selection: $tab
                    )
                    .padding(.horizontal, Spacing.margin)
                    .padding(.vertical, Spacing.snug)
                    switch tab {
                    case .info:
                        EventInfo(
                            event: event,
                            occurrence: occurrence,
                            count: count,
                            showInterested: { tab = .interested },
                            choose: { chosen = $0 },
                            confirm: { confirmation = $0 }
                        )
                    case .interested:
                        EventInterestedList(event: event, occurrence: occurrence, count: count)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .softScrollEdgesVertical()
            Rectangle().fill(Palette.selectionFill).frame(height: 1)
            HStack {
                Spacer(minLength: 0)
                EventActionBar(event: event, occurrence: occurrence)
            }
            .padding(Spacing.margin)
        }
        .eventConfirmation($confirmation, for: event)
        // Discord asks for the shown date's count, and the reader's answers,
        // whenever the date changes.
        .task(id: occurrence) {
            model.sessionController.loadEventCounts(event, occurrences: occurrence.map { [$0] } ?? [])
        }
    }
}

// MARK: - Event Info

private struct EventInfo: View {
    var event: ScheduledEvent
    var occurrence: UInt64?
    var count: Int?
    var showInterested: () -> Void
    var choose: (UInt64) -> Void
    var confirm: (EventConfirmation) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let span = event.span(of: occurrence)
        let clock = EventClock.current()
        VStack(alignment: .leading, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                EventTimeLine(
                    start: span.start,
                    end: span.end,
                    status: event.status(of: occurrence),
                    isExternal: event.location.externalLocation != nil,
                    isCanceled: event.exception(for: occurrence)?.isCanceled == true,
                    repeatLine: event.rule.flatMap { EventTimeText.repeatLine(for: $0, at: span.start, clock: clock) }
                )
                Text(event.name)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .textSelection(.enabled)
            }
            guildRow
            placeRow
            if let count {
                infoRow(symbol: "person.2.fill") {
                    Button(action: showInterested) {
                        Text("\(count.formatted()) \(count == 1 ? "person is" : "people are") interested")
                            .foregroundStyle(InkColor.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            creatorRow
            if let description = event.description, !description.isEmpty {
                ProseText(
                    markdown: description,
                    font: .body,
                    color: InkColor.primary,
                    mentions: model.mentionContext(),
                    onLink: { model.openLinkFromEvents($0) }
                )
                .padding(.top, Spacing.tight)
            }
            if event.rule != nil {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                    .padding(.vertical, Spacing.tight)
                EventSeriesList(event: event, shown: occurrence, choose: choose, confirm: confirm)
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            Image(symbol: symbol)
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            content()
                .font(.system(.subheadline))
        }
    }

    /// The server — a way into it, as Discord's row is.
    @ViewBuilder
    private var guildRow: some View {
        if let guild = model.guilds[event.guildID] {
            HStack(spacing: Spacing.base) {
                GuildAvatar(
                    url: guild.iconHash.flatMap { CDN.guildIcon(guildID: guild.id, hash: $0, side: 20) },
                    name: guild.name,
                    side: 20
                )
                Button {
                    model.eventsPanel = nil
                    model.selectGuild(guild.id)
                } label: {
                    Text(guild.name)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Server: \(guild.name)"))
            }
        }
    }

    @ViewBuilder
    private var placeRow: some View {
        switch event.location {
        case .unrecognised:
            EmptyView()
        default:
            EventPlaceLabel(event: event)
        }
    }

    /// "Created by" and the maker's name, which opens their profile.
    @ViewBuilder
    private var creatorRow: some View {
        if let creatorID = event.creatorID, let creator = model.users[creatorID] {
            let name = model.voiceName(of: creatorID, inGuild: event.guildID)
            HStack(spacing: Spacing.base) {
                AvatarView(
                    url: model.avatarURL(forUserID: creatorID, inGuild: event.guildID, side: 20),
                    monogram: creator.monogram,
                    side: 20
                )
                Text("Created by")
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                Button {
                    model.openProfile(creatorID, anchor: .zero, depth: .full)
                } label: {
                    Text(name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                }
                .buttonStyle(.plain)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Events in series

/// A series' dates from now, four at a time — Discord's list (`620018`). A
/// date that is not cancelled makes the page that date's; each has its own
/// menu.
private struct EventSeriesList: View {
    var event: ScheduledEvent
    var shown: UInt64?
    var choose: (UInt64) -> Void
    var confirm: (EventConfirmation) -> Void

    @Environment(AppModel.self) private var model
    @State private var dates: [UInt64] = []

    /// Discord's page: four dates, and View future events for four more.
    private static let page = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("Events in series")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.secondary)
            ForEach(dates, id: \.self) { date in
                EventSeriesRow(
                    event: event,
                    occurrence: date,
                    isShown: date == shown,
                    choose: { choose(date) },
                    confirm: confirm
                )
            }
            if hasMore {
                Button("View future events") { extend() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .task(id: event.rule) {
            dates = event.upcomingOccurrences(limit: Self.page)
            loadCounts()
        }
    }

    /// More to show while the next date after the last falls within the four
    /// years Discord looks ahead.
    private var hasMore: Bool {
        guard let rule = event.rule, let last = dates.last else { return false }
        let horizon = Calendar(identifier: .gregorian).date(byAdding: .year, value: 4, to: .now) ?? .now
        guard let next = rule.occurrence(after: ScheduledEvent.originalStart(ofOccurrence: last)) else { return false }
        return next <= horizon
    }

    private func extend() {
        guard let last = dates.last else { return }
        dates += event.upcomingOccurrences(
            limit: Self.page, after: ScheduledEvent.originalStart(ofOccurrence: last)
        )
        loadCounts()
    }

    /// Each date's count, as Discord asks for the dates it lists.
    private func loadCounts() {
        model.sessionController.loadEventCounts(event, occurrences: dates)
    }
}

private struct EventSeriesRow: View {
    var event: ScheduledEvent
    var occurrence: UInt64
    var isShown: Bool
    var choose: () -> Void
    var confirm: (EventConfirmation) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        let span = event.span(of: occurrence)
        let isCanceled = event.exception(for: occurrence)?.isCanceled == true
        HStack(spacing: Spacing.base) {
            EventTimeLine(
                start: span.start,
                end: nil,
                status: event.status(of: occurrence),
                isExternal: event.location.externalLocation != nil,
                isCanceled: isCanceled
            )
            .opacity(isCanceled ? 0.6 : 1)
            if isCanceled {
                Text("Canceled")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
            Spacer(minLength: Spacing.base)
            EventMoreMenu(event: event, occurrence: occurrence, isSeriesDate: true, confirm: confirm)
                .controlSize(.small)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isShown ? Palette.selectionFill : isHovering ? Palette.hoverFill : Palette.groupedFill)
        }
        .contentShape(.rect)
        .onTapGesture { if !isCanceled { choose() } }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Show")) { if !isCanceled { choose() } }
    }
}

// MARK: - Interested

/// Who is interested in the shown date: the series' people less those who
/// said "not this one", and those who said yes to this one alone — Discord's
/// merge, in its order. A hundred at most, with a line for the rest.
private struct EventInterestedList: View {
    var event: ScheduledEvent
    var occurrence: UInt64?
    var count: Int?

    @Environment(AppModel.self) private var model
    @State private var people: [ScheduledEventInterest]?
    @State private var failed = false

    /// Discord's page — `C.C1`, asked for as `limit=100`.
    private static let limit = 100

    var body: some View {
        Group {
            if let people {
                if people.isEmpty {
                    placeholder("No one's interested in this event yet.", isHeading: true)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(people, id: \.user.id) { person in
                            EventInterestedRow(userID: person.user.id, guildID: event.guildID)
                        }
                        let rest = remaining(shown: people.count)
                        if rest > 0 {
                            Text("\(rest.formatted()) more \(rest == 1 ? "person is" : "people are") interested.")
                                .font(.system(.subheadline))
                                .foregroundStyle(InkColor.secondary)
                                .padding(.horizontal, Spacing.snug)
                                .padding(.vertical, Spacing.base)
                        }
                    }
                    .padding(.horizontal, Spacing.base)
                    .padding(.bottom, Spacing.margin)
                }
            } else if failed {
                placeholder(
                    "We are having problems looking up who is interested in this event. Please try again later.",
                    isHeading: false
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.section)
            }
        }
        .task(id: occurrence) { await load() }
    }

    private func load() async {
        failed = false
        // The series' people, and the date's own answers — two requests, as
        // Discord makes them, merged by its rule.
        async let series = model.sessionController.interestedPeople(in: event, at: nil)
        async let date = occurrence == nil
            ? [ScheduledEventInterest]?.some([])
            : model.sessionController.interestedPeople(in: event, at: occurrence)
        guard let series = await series, let date = await date else {
            failed = true
            return
        }
        let answers = Dictionary(date.map { ($0.user.id, $0.rsvp.response) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UserID>()
        var merged: [ScheduledEventInterest] = []
        for person in series where answers[person.user.id] != .uninterested {
            if seen.insert(person.user.id).inserted { merged.append(person) }
        }
        for person in date where person.rsvp.response == .interested {
            if seen.insert(person.user.id).inserted { merged.append(person) }
        }
        people = merged
    }

    /// Discord counts the rest only once a full page came back.
    private func remaining(shown: Int) -> Int {
        guard shown >= Self.limit, let count, count > Self.limit else { return 0 }
        return max(count - shown, 0)
    }

    private func placeholder(_ text: String, isHeading: Bool) -> some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 32))
                .foregroundStyle(InkColor.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(isHeading ? .system(.title3, weight: .semibold) : .system(.subheadline, weight: .semibold))
                .foregroundStyle(isHeading ? InkColor.primary : InkColor.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.section)
    }
}

/// One person interested — their face, with their status, and their name in
/// the server. A click opens their profile, a right-click their menu.
private struct EventInterestedRow: View {
    var userID: UserID
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        let name = model.voiceName(of: userID, inGuild: guildID)
        HStack(spacing: Spacing.base) {
            AvatarView(
                url: model.avatarURL(forUserID: userID, inGuild: guildID, side: 24),
                monogram: model.users[userID]?.monogram ?? "?",
                side: 24
            )
            .overlay(alignment: .bottomTrailing) {
                // No plate: a disc of the window's colour on glass reads as
                // a blot, which is the profile's reason for going without.
                PresenceDot(status: model.presenceStatus(of: userID), side: 9, hasPlate: false)
                    .offset(x: 2, y: 2)
            }
            Text(name)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: 40)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(Palette.hoverFill)
            }
        }
        .contentShape(.rect)
        .onTapGesture { model.openProfile(userID, anchor: .zero, depth: .full) }
        .onSecondaryClick { anchor in
            model.openUserMenu(for: userID, anchor: anchor, inGuild: guildID)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.openProfile(userID, anchor: .zero, depth: .full) }
    }
}
