import SwiftUI
import WingcordCore

/// One card of the Rich Presence builder: Discord's activity card
/// (`CurrentActivityCard`, line for line), every part of it editable where it
/// sits — so what is typed is the live preview of what everybody else sees.
///
/// **The words are Vencord's CustomRPC's**: its field labels are the
/// placeholders, and what is wrong with a field is said under it in its words
/// (`CustomPresence.problem`). The pictures show only when they would go out —
/// they go through the application, so without its ID the wells stay empty.
struct EditablePresenceCard: View {
    var presence: CustomPresence
    var isOn: Bool
    var ground: ProfileGround
    var update: (CustomPresence) -> Void
    var turnOn: (Bool) -> Void
    var remove: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var openArt: ArtSlot?
    @State private var openLink: LinkSlot?

    private enum ArtSlot: Hashable {
        case large, small
    }

    private enum LinkSlot: Hashable {
        case details, state, button(Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            if presence.kind == .streaming {
                PresenceField(
                    "Stream Link", text: binding(\.streamLink), problem: presence.problem(.streamLink)
                )
                .help("Stream Link (Twitch or YouTube, only if activity type is Streaming)")
            }
            HStack(alignment: .center, spacing: Spacing.base) {
                artWells
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    // A new card is not wrong yet: Vencord says a name is
                    // required once something is typed, and so does this once
                    // the card is on.
                    PresenceField(
                        "Application Name", text: binding(\.name),
                        problem: presence.name.isEmpty && !isOn ? nil : presence.problem(.name),
                        font: .system(.subheadline, weight: .semibold), ink: InkColor.primary
                    )
                    line("Detail (line 1)", text: \.details, problem: .details, link: .details)
                    line("State (line 2)", text: \.state, problem: .state, link: .state)
                    timerRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            buttonRows
            if presence.kind == .playing { partyRow }
            applicationRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The header

    /// The type as the card's own header reads it, chosen from Vencord's five;
    /// whether this is the card that is on; and its menu.
    private var header: some View {
        HStack(spacing: Spacing.tight) {
            Menu {
                Picker("Activity Type", selection: binding(\.kind)) {
                    ForEach(CustomPresence.Kind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(presence.kind.title)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(InkColor.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: Spacing.base)
            Toggle("Show Custom RPC", isOn: Binding(get: { isOn }, set: turnOn))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Show Custom RPC")
            Menu {
                Button("Remove", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Options"))
        }
    }

    // MARK: The lines

    private func line(
        _ placeholder: String,
        text: WritableKeyPath<CustomPresence, String>,
        problem: CustomPresence.Field,
        link: LinkSlot
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            PresenceField(placeholder, text: binding(text), problem: presence.problem(problem))
            linkButton(link)
        }
    }

    /// A line's or a button's link, behind a glyph that is lit while one is set.
    private func linkButton(_ slot: LinkSlot) -> some View {
        let isSet = !link(of: slot).isEmpty
        return Button { openLink = slot } label: {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSet ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(InkColor.tertiary))
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(linkTitle(slot))
        .popover(
            isPresented: Binding(get: { openLink == slot }, set: { if !$0 { openLink = nil } }),
            arrowEdge: .bottom
        ) {
            PresenceField(
                linkTitle(slot), text: binding(linkPath(slot)), problem: presence.problem(linkField(slot)),
                isBoxed: true
            )
            .padding(Spacing.margin)
            .frame(width: 300)
            .profileFlyoutAppearance()
        }
    }

    private func link(of slot: LinkSlot) -> String { presence[keyPath: linkPath(slot)] }

    private func linkPath(_ slot: LinkSlot) -> WritableKeyPath<CustomPresence, String> {
        switch slot {
        case .details: \.detailsLink
        case .state: \.stateLink
        case .button(let index): \.buttons[index].link
        }
    }

    private func linkField(_ slot: LinkSlot) -> CustomPresence.Field {
        switch slot {
        case .details: .detailsLink
        case .state: .stateLink
        case .button(let index): .buttonLink(index)
        }
    }

    private func linkTitle(_ slot: LinkSlot) -> String {
        switch slot {
        case .details: "Detail URL"
        case .state: "State URL"
        case .button(let index): "Button\(index + 1) URL"
        }
    }

    // MARK: The clock

    /// Vencord's Timestamp Mode, where the card draws its clock.
    @ViewBuilder
    private var timerRow: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
            Menu {
                ForEach(Self.timers, id: \.title) { timer in
                    Button(timer.title) { set(\.timer, to: timer) }
                }
            } label: {
                Text(presence.timer.title)
                    .font(.system(.caption))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .foregroundStyle(InkColor.tertiary)
        if case .custom(let start, let end) = presence.timer {
            customTime("Start Timestamp", date: start) { set(\.timer, to: .custom(start: $0, end: end)) }
            customTime("End Timestamp", date: end) { set(\.timer, to: .custom(start: start, end: $0)) }
        }
    }

    private static let timers: [CustomPresence.Timer] = [.none, .sinceOn, .localTime, .custom(start: nil, end: nil)]

    /// One of Custom's two moments, either of which may be left out.
    private func customTime(_ title: String, date: Date?, set: @escaping (Date?) -> Void) -> some View {
        HStack(spacing: Spacing.tight) {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { set($0 ? .now : nil) }))
                .toggleStyle(.checkbox)
                .font(.system(.caption))
            if let date {
                DatePicker(title, selection: Binding(get: { date }, set: { set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .foregroundStyle(InkColor.secondary)
    }

    // MARK: The pictures

    /// The large picture and the badge on its corner, each a well that opens
    /// its fields.
    private var artWells: some View {
        ZStack(alignment: .bottomTrailing) {
            Button { openArt = .large } label: {
                well(presence.largeArt, side: CurrentActivityCard.artworkSide)
                    .clipShape(.rect(cornerRadius: CurrentActivityCard.corner, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(presence.largeArt.text)
            .accessibilityLabel(Text("Large Image URL/Key"))
            .popover(isPresented: art(.large), arrowEdge: .bottom) { artEditor(.large).profileFlyoutAppearance() }

            Button { openArt = .small } label: {
                well(presence.smallArt, side: CurrentActivityCard.badgeSide)
                    .clipShape(.circle)
                    .overlay { Circle().strokeBorder(Palette.canvas, lineWidth: 2) }
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: 6)
            .help(presence.smallArt.text)
            .accessibilityLabel(Text("Small Image URL/Key"))
            .popover(isPresented: art(.small), arrowEdge: .bottom) { artEditor(.small).profileFlyoutAppearance() }
        }
        .frame(width: CurrentActivityCard.artworkSide, height: CurrentActivityCard.artworkSide)
    }

    private func well(_ art: CustomPresence.Art, side: CGFloat) -> some View {
        RemoteImage(url: previewURL(art, side: side), side: side, bucket: .artwork) {
            ZStack {
                Rectangle().fill(ground.panelFill)
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: side * 0.32))
                    .foregroundStyle(InkColor.tertiary)
            }
        }
        .aspectRatio(contentMode: .fill)
        .frame(width: side, height: side)
    }

    /// What the picture will be once it goes out — **only where it can**, so
    /// the well never shows a picture nobody else will see.
    private func previewURL(_ art: CustomPresence.Art, side: CGFloat) -> URL? {
        guard presence.carriesArt, !art.image.isEmpty else { return nil }
        let application = UInt64(presence.applicationID).map(ApplicationID.init(rawValue:))
        if let resolved = model.customPresenceAssets[presence.applicationID + " " + art.image] {
            return Activity.assetURL(resolved, application: application, side: side)
        }
        return art.image.hasPrefix("http") ? URL(string: art.image) : nil
    }

    private func art(_ slot: ArtSlot) -> Binding<Bool> {
        Binding(get: { openArt == slot }, set: { if !$0 { openArt = nil } })
    }

    /// Vencord's three fields for a picture — and, until there is one, the
    /// Application ID the picture needs.
    private func artEditor(_ slot: ArtSlot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if !presence.carriesArt {
                PresenceField(
                    "Application ID", text: binding(\.applicationID),
                    problem: presence.problem(.applicationID), isBoxed: true
                )
            }
            switch slot {
            case .large:
                PresenceField("Large Image URL/Key", text: binding(\.largeArt.image), problem: presence.problem(.largeImage), isBoxed: true)
                PresenceField("Large Image Text", text: binding(\.largeArt.text), problem: presence.problem(.largeText), isBoxed: true)
                PresenceField("Large Image clickable URL", text: binding(\.largeArt.link), problem: presence.problem(.largeLink), isBoxed: true)
            case .small:
                PresenceField("Small Image URL/Key", text: binding(\.smallArt.image), problem: presence.problem(.smallImage), isBoxed: true)
                PresenceField("Small Image Text", text: binding(\.smallArt.text), problem: presence.problem(.smallText), isBoxed: true)
                PresenceField("Small Image clickable URL", text: binding(\.smallArt.link), problem: presence.problem(.smallLink), isBoxed: true)
            }
        }
        .padding(Spacing.margin)
        .frame(width: 320)
    }

    // MARK: The buttons, the party, the application

    /// The card's two buttons, drawn as the buttons they become — stacked and
    /// full width, the label typed where it will read.
    private var buttonRows: some View {
        VStack(spacing: Spacing.base) {
            // The card's own slots — always two, but a list read back from
            // disk is not indexed past its end.
            ForEach(Array(presence.buttons.indices.prefix(2)), id: \.self) { index in
                HStack(spacing: Spacing.tight) {
                    PresenceField(
                        "Button\(index + 1) Text", text: binding(\.buttons[index].label),
                        problem: presence.problem(.buttonLabel(index)),
                        font: .system(.body), ink: InkColor.primary, alignment: .center
                    )
                    linkButton(.button(index))
                }
                .padding(.horizontal, Spacing.snug)
                .frame(minHeight: Metrics.control + 4)
                .background(InkColor.primary.opacity(0.1), in: .rect(cornerRadius: Radius.chip, style: .continuous))
            }
        }
    }

    private var partyRow: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(InkColor.tertiary)
            PresenceField("Party Size", text: binding(\.partySize), problem: presence.problem(.partySize))
            PresenceField("Maximum Party Size", text: binding(\.partyMax), problem: presence.problem(.partyMax))
        }
    }

    private var applicationRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            PresenceField(
                "Application ID", text: binding(\.applicationID), problem: presence.problem(.applicationID),
                ink: InkColor.tertiary
            )
            Button { openURL(Self.developerPortal) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(InkColor.tertiary)
            }
            .buttonStyle(.plain)
            .help(Self.developerPortal.absoluteString)
            .accessibilityLabel(Text(Self.developerPortal.absoluteString))
        }
    }

    /// Where an Application ID comes from.
    private static let developerPortal = URL(string: "https://discord.com/developers/applications")!

    // MARK: Writing

    private func binding<Value>(_ path: WritableKeyPath<CustomPresence, Value>) -> Binding<Value> {
        Binding(get: { presence[keyPath: path] }, set: { set(path, to: $0) })
    }

    private func set<Value>(_ path: WritableKeyPath<CustomPresence, Value>, to value: Value) {
        var next = presence
        next[keyPath: path] = value
        update(next)
    }
}

/// One of the card's fields: plain where it sits in the card, boxed in a
/// popover, and Vencord's word on what is wrong with it underneath.
private struct PresenceField: View {
    var placeholder: String
    @Binding var text: String
    var problem: String?
    var font: Font = .system(.caption)
    var ink: Color = InkColor.secondary
    var alignment: TextAlignment = .leading
    var isBoxed = false

    init(
        _ placeholder: String,
        text: Binding<String>,
        problem: String?,
        font: Font = .system(.caption),
        ink: Color = InkColor.secondary,
        alignment: TextAlignment = .leading,
        isBoxed: Bool = false
    ) {
        self.placeholder = placeholder
        _text = text
        self.problem = problem
        self.font = font
        self.ink = ink
        self.alignment = alignment
        self.isBoxed = isBoxed
    }

    var body: some View {
        VStack(alignment: alignment == .center ? .center : .leading, spacing: 2) {
            if isBoxed {
                TextField(placeholder, text: $text, prompt: Text(placeholder))
                    .modalField()
                    .font(font)
            } else {
                TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(InkColor.tertiary))
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(ink)
                    .multilineTextAlignment(alignment)
            }
            if let problem {
                Text(problem)
                    .font(.system(.caption2))
                    .foregroundStyle(Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}
