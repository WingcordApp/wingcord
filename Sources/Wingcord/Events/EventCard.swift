import SwiftUI
import WingcordCore

/// One event in the list — Discord's card (`779519` over `557582`): the cover
/// across the top, when it is and who made it and how many are interested,
/// the name and the start of the description, then where it is and what the
/// reader can do about it. A click anywhere else opens the event.
///
/// **A flat fill and a hairline**, `InboxGroupCard`'s recipe: this sits on the
/// panel's own glass, and a material here would be two in series.
struct EventCard: View {
    var event: ScheduledEvent
    var isNew: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    /// Discord's thumbnail: 120 points tall, the card's full width.
    private static let coverHeight: CGFloat = 120

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
        let occurrence = event.currentOccurrenceID
        let span = event.span(of: occurrence)
        let isJoined = event.status == .active
            && event.location.channelID != nil
            && event.location.channelID == model.connectedVoiceChannelID
        VStack(alignment: .leading, spacing: 0) {
            if let cover = event.imageHash.flatMap({ CDN.scheduledEventCover(eventID: event.id, hash: $0, side: 560) }) {
                RemoteImage(url: cover, side: 560, bucket: .artwork) {
                    Palette.hoverFill
                }
                .aspectRatio(contentMode: .fill)
                .frame(height: Self.coverHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    EventTimeLine(
                        start: span.start,
                        end: span.end,
                        status: event.status(of: occurrence),
                        isExternal: event.location.externalLocation != nil,
                        isCanceled: event.exception(for: occurrence)?.isCanceled == true,
                        isNew: isNew
                    )
                    Spacer(minLength: Spacing.base)
                    EventCreatorMark(event: event)
                    EventInterestedPill(count: model.interestedCount(for: event, at: occurrence))
                }
                .padding(.bottom, Spacing.snug)
                Text(event.name)
                    .font(.system(.title3, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                if let description = event.description, !description.isEmpty {
                    ProseText(
                        markdown: description,
                        font: .subheadline,
                        color: InkColor.secondary,
                        onLink: { model.openLink($0) }
                    )
                    .lineLimit(3)
                    .padding(.top, Spacing.base)
                }
            }
            .padding(Spacing.margin)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: Spacing.base) {
                EventPlaceLabel(event: event)
                Spacer(minLength: Spacing.base)
                EventActionBar(event: event, occurrence: occurrence)
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, Spacing.snug)
        }
        .background(isHovering ? Palette.hoverFill : Palette.groupedFill, in: shape)
        .clipShape(shape)
        .overlay {
            // Discord rings the event the reader is sitting in.
            shape.strokeBorder(isJoined ? Palette.presenceOnline : Palette.hairline, lineWidth: 1)
        }
        .contentShape(shape)
        .onTapGesture { model.showEvent(event.id, occurrence: occurrence) }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(event.name))
        .accessibilityAction(named: Text("Open")) { model.showEvent(event.id, occurrence: occurrence) }
    }
}

/// The face of whoever made the event, named on hover — Discord's 20-point
/// creator mark.
struct EventCreatorMark: View {
    var event: ScheduledEvent

    @Environment(AppModel.self) private var model

    var body: some View {
        // The panel puts each event's `creator` into the store as it opens.
        if let creatorID = event.creatorID, let creator = model.users[creatorID] {
            let name = model.voiceName(of: creatorID, inGuild: event.guildID)
            AvatarView(
                url: model.avatarURL(forUserID: creatorID, inGuild: event.guildID, side: 20),
                monogram: creator.monogram,
                side: 20
            )
            .help("Created by \(name)")
            .accessibilityLabel(Text("Created by \(name)"))
        }
    }
}

/// How many are interested — Discord's count pill.
struct EventInterestedPill: View {
    var count: Int?

    var body: some View {
        if let count {
            let words = "\(count.formatted()) \(count == 1 ? "person is" : "people are") interested"
            HStack(spacing: Spacing.tight) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(count.formatted())
                    .font(.system(.subheadline))
                    .monospacedDigit()
            }
            .foregroundStyle(InkColor.primary)
            .padding(.horizontal, Spacing.base)
            .frame(height: 20)
            .background(Capsule().fill(Palette.selectionFill))
            .help(words)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(words))
        }
    }
}

/// Where the event is: its room, which a click joins, or the place somebody
/// wrote, which may hold links — Discord's location row.
struct EventPlaceLabel: View {
    var event: ScheduledEvent

    @Environment(AppModel.self) private var model

    var body: some View {
        switch event.location {
        case .external(let place):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(InkColor.secondary)
                    .accessibilityHidden(true)
                ProseText(
                    markdown: place,
                    font: .subheadline,
                    color: InkColor.primary,
                    onLink: { model.openLink($0) }
                )
                .lineLimit(1)
            }
        case .voice(let channelID), .stage(let channelID):
            let channel = model.channelIndex[channelID]
            let canJoin = model.permissionGate.canJoinVoice(channelID)
            Button {
                model.joinEventRoom(event)
            } label: {
                HStack(spacing: 6) {
                    Image(symbol: channel?.kind.symbolName ?? event.location.symbolName)
                        .accessibilityHidden(true)
                    Text(channel.map(model.displayName(of:)) ?? "Unknown channel")
                        .lineLimit(1)
                }
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.primary)
            }
            .buttonStyle(.plain)
            .disabled(!canJoin)
            .help(canJoin ? "" : "Missing permission to connect.")
        case .unrecognised:
            EmptyView()
        }
    }
}
