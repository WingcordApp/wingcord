import SwiftUI
import WingcordCore

/// Discord's event embed (`427080`): the cover across the top; when it is, who
/// made it and how many are interested; the name and the start of the
/// description; then the server and the place, and one button.
///
/// **The events panel's own parts on the transcript's card ground.** The time
/// line, the maker's face and the count are `EventCard`'s; the plate is a drawn
/// embed's — its fill, its hairline, its corner — so the card sits among the
/// transcript's other cards as one of them.
///
/// **As wide as its column, up to Discord's 432** (`.wrapper_d5f3cd`), and it
/// reports its height at that width, because the description wraps to it — see
/// `HostedCardMeasure`. Only a reader in the event's server can open it, as
/// only theirs is `.clickable_da5e8d`.
struct EventLinkCard: View {
    var key: EventCardKey
    var isMeasuring = false

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    /// The date whose Interested asked "the series, or this one?".
    @State private var askedDate: UInt64?

    /// `.container__652b4{height:164px}`.
    private static let coverHeight: CGFloat = 164

    var body: some View {
        if let event = model.cardEvent(for: key) {
            plate(event)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    // A measuring card reports through its caller, once.
                    guard !isMeasuring else { return }
                    model.noteHostedCardSize(size, for: .event(key))
                }
        }
    }

    private func plate(_ event: ScheduledEvent) -> some View {
        let shape = RoundedRectangle(cornerRadius: EmbedLayoutEngine.corner, style: .continuous)
        let isMember = model.guilds[key.guildID] != nil
        let occurrence = model.cardOccurrence(for: key, of: event)
        return VStack(alignment: .leading, spacing: 0) {
            if let cover = event.imageHash.flatMap({
                CDN.scheduledEventCover(eventID: event.id, hash: $0, side: Metrics.embedMaxWidth)
            }) {
                RemoteImage(url: cover, side: Metrics.embedMaxWidth, bucket: .artwork) {
                    Palette.hoverFill
                }
                .aspectRatio(contentMode: .fill)
                .frame(height: Self.coverHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                header(event, occurrence: occurrence)
                    .padding(.bottom, Spacing.snug)
                EventCardName(name: event.name, underlinesOnHover: isMember)
                if let description = event.description, !description.isEmpty {
                    ProseText(
                        markdown: description,
                        font: .subheadline,
                        color: InkColor.secondary,
                        onLink: { model.openLink($0) }
                    )
                    .lineLimit(4)
                    .padding(.top, Spacing.base)
                }
                footer(event, occurrence: occurrence)
                    .padding(.top, Spacing.snug)
            }
            .padding(Spacing.margin)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A drawn embed's own fill — `ThemeInk.cardFill`, the raised
            // surface at 85% — and Discord's `--background-mod-normal` over it
            // under the pointer.
            shape.fill(Palette.surfaceRaised.opacity(0.85))
            if isMember && isHovering { shape.fill(Palette.hoverFill) }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.hoverFill, lineWidth: 1) }
        .contentShape(shape)
        .onTapGesture { model.openCardEvent(key, event: event) }
        .onHover { hovering in
            guard isMember, isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(event.name))
        .accessibilityActions {
            if isMember {
                Button("Open") { model.openCardEvent(key, event: event) }
            }
        }
    }

    /// When, who and how many — `557582`'s status row.
    private func header(_ event: ScheduledEvent, occurrence: UInt64?) -> some View {
        let span = event.span(of: occurrence)
        return HStack(alignment: .top, spacing: Spacing.base) {
            EventTimeLine(
                start: span.start,
                end: span.end,
                status: event.status(of: occurrence),
                isExternal: event.location.externalLocation != nil,
                isCanceled: event.exception(for: occurrence)?.isCanceled == true
            )
            Spacer(minLength: Spacing.base)
            EventCreatorMark(event: event)
            EventInterestedPill(count: model.interestedCount(for: event, at: occurrence))
        }
    }

    /// The server and the place on the left, the button pushed right — and
    /// the button under them when the two do not fit on one line
    /// (`.footerContainer_da5e8d{flex-flow:row wrap}`). With no server to
    /// name, the button alone, at the start.
    @ViewBuilder
    private func footer(_ event: ScheduledEvent, occurrence: UInt64?) -> some View {
        if let server = model.cardServer(for: key) {
            let line = EventCardServerLine(key: key, server: server, event: event)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.margin) {
                    line
                    Spacer(minLength: 0)
                    button(event, occurrence: occurrence)
                }
                VStack(alignment: .leading, spacing: Spacing.margin) {
                    line
                    button(event, occurrence: occurrence)
                }
            }
        } else {
            button(event, occurrence: occurrence)
        }
    }

    /// Discord's one button — see `EventCardAction`.
    private func button(_ event: ScheduledEvent, occurrence: UInt64?) -> some View {
        let action = model.cardAction(for: key, event: event)
        return Button {
            perform(action, event: event, occurrence: occurrence)
        } label: {
            HStack(spacing: Spacing.tight) {
                if case .interested(let isIn) = action {
                    Image(systemName: isIn ? "checkmark" : "bell")
                        .accessibilityHidden(true)
                }
                Text(action.title)
            }
        }
        .buttonStyle(EmbedButtonStyle(isProminent: action.isProminent))
        .disabled(action == .over)
        .accessibilityAddTraits(action == .interested(true) ? .isSelected : [])
        .popover(
            isPresented: Binding(get: { askedDate != nil }, set: { if !$0 { askedDate = nil } }),
            arrowEdge: .bottom
        ) {
            if let askedDate {
                EventSeriesChoice(event: event, occurrence: askedDate) { self.askedDate = nil }
            }
        }
    }

    private func perform(_ action: EventCardAction, event: ScheduledEvent, occurrence: UInt64?) {
        switch action {
        case .joinServer:
            model.joinCardServer(key)
        case .viewDetails:
            model.openCardEvent(key, event: event)
        case .goToChannel, .join:
            model.joinEventRoom(event)
        case .over:
            break
        case .interested:
            switch model.interestStep(for: event, at: occurrence) {
            case .ask(let date): askedDate = date
            case let step: model.apply(step, to: event)
            }
        }
    }
}

/// The event's name, on one line, underlined under the pointer where the card
/// opens — `.eventName_b5010b:hover`.
private struct EventCardName: View {
    var name: String
    var underlinesOnHover: Bool

    @State private var isHovering = false

    var body: some View {
        Text(name)
            .font(.system(.title3, weight: .medium))
            .foregroundStyle(InkColor.primary)
            .underline(underlinesOnHover && isHovering)
            .lineLimit(1)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
    }
}

/// The footer's left half (`427080`'s `U`): the server's icon, its mark and
/// name, and where the event is under them. For a reader in the server the
/// icon and the name go there and the room joins; for anybody else they are
/// only words.
private struct EventCardServerLine: View {
    var key: EventCardKey
    var server: EventCardServer
    var event: ScheduledEvent

    @Environment(AppModel.self) private var model

    private var isMember: Bool { model.guilds[key.guildID] != nil }

    var body: some View {
        HStack(spacing: Spacing.margin) {
            Button {
                model.openCardServer(key, event: event)
            } label: {
                icon
            }
            .buttonStyle(.plain)
            .disabled(!isMember)
            .accessibilityLabel(Text(server.name))
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.tight) {
                    if let mark = server.mark {
                        GuildMarkBadge(mark: mark, side: 16)
                    }
                    Button(server.name) { model.openCardServer(key, event: event) }
                        .buttonStyle(UnderlinesOnHover(isLive: isMember))
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                        .disabled(!isMember)
                }
                place
            }
        }
    }

    /// The classic invite card's icon: 48, its corner 14, the server's letters
    /// where it has no picture.
    private var icon: some View {
        let side = InviteCardLayoutEngine.classicIconSide
        return RemoteImage(url: server.iconURL, side: side) {
            Text(server.monogram)
                .font(.system(size: side * 0.36, weight: .semibold))
                .foregroundStyle(InkColor.secondary)
                .frame(width: side, height: side)
                .background(Palette.hoverFill)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: InviteCardLayoutEngine.classicIconCorner, style: .continuous))
    }

    /// Where it is — `515115`'s place: the place somebody wrote, or the room,
    /// which a reader in the server joins from here.
    @ViewBuilder
    private var place: some View {
        switch event.location {
        case .external(let written):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                Image(symbol: event.location.symbolName)
                    .accessibilityHidden(true)
                ProseText(markdown: written, font: .caption, color: InkColor.primary, onLink: { model.openLink($0) })
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(InkColor.primary)
        case .voice(let channelID), .stage(let channelID):
            if let name = model.cardChannelName(for: key, channelID: channelID) {
                Button {
                    model.joinCardPlace(event)
                } label: {
                    HStack(spacing: Spacing.tight) {
                        Image(symbol: model.channelIndex[channelID]?.kind.symbolName ?? event.location.symbolName)
                            .accessibilityHidden(true)
                        Text(name).lineLimit(1)
                    }
                }
                .buttonStyle(UnderlinesOnHover(isLive: isMember))
                .font(.caption)
                .foregroundStyle(InkColor.primary)
                .disabled(!isMember)
            }
        case .unrecognised:
            EmptyView()
        }
    }
}

/// Discord's embed button — the Mana button at its default size (`657718`,
/// `.md_a22cb0`): 40 tall, at least 100 wide, 16 either side of its words,
/// its corner 8; the green "active" face (`--control-connected-*`, the invite
/// card's Join) or the grey "secondary" one; and half there when disabled.
private struct EmbedButtonStyle: ButtonStyle {
    var isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, isProminent: isProminent)
    }

    private struct Face: View {
        let configuration: ButtonStyle.Configuration
        var isProminent: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: EmbedLayoutEngine.corner, style: .continuous)
            configuration.label
                .font(.system(.body, weight: .medium))
                .foregroundStyle(isProminent ? AnyShapeStyle(Color.white) : AnyShapeStyle(InkColor.primary))
                .lineLimit(1)
                .padding(.horizontal, Spacing.margin)
                .frame(minWidth: 100, minHeight: 40)
                .background(fill, in: shape)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(shape)
                .onHover { hovering in
                    guard isHovering != hovering else { return }
                    isHovering = hovering
                }
        }

        private var fill: Color {
            let isLit = isEnabled && (isHovering || configuration.isPressed)
            if isProminent {
                return Color(cgColor: isLit ? TimelineRowPainter.joinFillHovered : TimelineRowPainter.joinFill)
            }
            // The painter's `ThemeInk.lift(0.12)`, and `lift(0.18)` lit.
            return isLit ? Color.relative(dark: 0.18, light: 0.135) : Color.relative(dark: 0.12, light: 0.09)
        }
    }
}
