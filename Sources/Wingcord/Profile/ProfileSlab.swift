import SwiftUI
import WingcordCore

/// One pane of the profile, floating over the ambient field.
///
/// **Clear glass, and that is the whole point of the redesign.** The old surface
/// filled these with `panelFill` — a sixteen-per-cent wash — because there was
/// nothing behind them worth refracting. With `AmbientArtwork` under the sheet
/// there is: each slab now lenses the person's own banner, which is what glass
/// is *for* and what the rest of this app has always done.
///
/// **One glass layer, not two.** The sheet's ground is opaque paint and the
/// field behind it is an image; this is the only glass between them and the
/// reader, so `INVARIANTS.md` §4 rule 2 is satisfied. The masthead bar that
/// floats over these when condensed is the app's existing `floatingTopBar`
/// idiom, which is the documented exception.
struct ProfileSlab<Content: View>: View {
    /// Nil draws no heading — which is what the application widget and the
    /// activity card want, because they carry their own.
    var title: String?
    var ground: ProfileGround
    /// A control pinned to the heading's trailing end, like a tile's "…".
    @ViewBuilder var accessory: () -> AnyView
    @ViewBuilder var content: () -> Content

    init(
        title: String? = nil,
        ground: ProfileGround,
        @ViewBuilder accessory: @escaping () -> AnyView = { AnyView(EmptyView()) },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.ground = ground
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if let title {
                HStack(spacing: Spacing.base) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                    Spacer(minLength: 0)
                    accessory()
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.margin)
        // Layout first, glass last — rule 1.
        //
        // **Tinted clear, not bare clear.** A fully clear body over a
        // low-contrast field is invisible at rest — the slabs came out as
        // wireframes, an outline with nothing inside it. The tint is part of the
        // material rather than a fill behind it; a fill under glass is what rule
        // 3 forbids and is exactly what stops a surface lensing. Same treatment
        // the selection indicator already takes for the same reason.
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Radius.glass, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
        }
    }
}

/// A slab whose content runs to its own edges — artwork, a cover grid.
///
/// The same material with no padding, because a header image inset by sixteen
/// points reads as a picture in a frame rather than as the top of a card.
struct ProfileBleedSlab<Content: View>: View {
    var ground: ProfileGround
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                .clear.tint(Palette.flyoutTint),
                in: .rect(cornerRadius: Radius.glass, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
            }
            .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
    }
}

// MARK: - The fact slabs

/// When they arrived, drawn as a line rather than as a form.
///
/// **The old surface had `MEMBER SINCE` and `NITRO` as two all-caps headings
/// over four label-value rows.** Five shouting headings down a column is what
/// made a person's profile read as a settings pane. Three dates on one thread,
/// oldest at the top, says the same thing as a shape — and the shape is the
/// point: it is a small life, not a table.
struct ProfileTimelineSlab: View {
    var profile: ProfilePresentation
    var ground: ProfileGround

    private struct Moment: Identifiable {
        var id: String
        var date: Date
        var label: String
        var iconURL: URL?
        var symbolName: String?
    }

    private var moments: [Moment] {
        var moments = [
            Moment(
                id: "discord",
                date: profile.accountCreated,
                label: "Joined Discord",
                symbolName: BrandMark.discord
            ),
        ]
        if let joined = profile.memberSince, let guild = profile.guild {
            moments.append(
                Moment(id: "guild", date: joined, label: guild.name, iconURL: guild.iconURL)
            )
        }
        if let premium = profile.premiumSince {
            moments.append(
                Moment(
                    id: "nitro",
                    date: premium,
                    label: profile.premiumTier.label ?? "Nitro",
                    symbolName: "sparkles"
                )
            )
        }
        return moments.sorted { $0.date < $1.date }
    }

    var body: some View {
        ProfileSlab(title: "Timeline", ground: ground) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                    row(moment, isLast: index == moments.count - 1)
                }
            }
        }
    }

    private func row(_ moment: Moment, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            VStack(spacing: 0) {
                marker(moment)
                if !isLast {
                    // The thread between two moments. It carries the eye down
                    // the column, which is the only reason the dates read as a
                    // sequence rather than as three unrelated rows.
                    Rectangle()
                        .fill(ground.borderStyle)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(moment.date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                Text(moment.label)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.tertiary)
                    .lineLimit(1)
            }
            .padding(.bottom, isLast ? 0 : Spacing.snug)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func marker(_ moment: Moment) -> some View {
        Group {
            if let url = moment.iconURL {
                RemoteImage(url: url, side: 22) { Circle().fill(Palette.surfaceRaised) }
                    .clipShape(.circle)
            } else if moment.symbolName == BrandMark.discord {
                ConnectionMark(service: BrandMark.discord, side: 22)
            } else if let symbolName = moment.symbolName {
                ZStack {
                    Circle().fill(Palette.surfaceRaised)
                    Image(systemName: symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(InkColor.secondary)
                }
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// The accounts they have linked, with what each service says about them.
///
/// **This is the half Wingcord was throwing away.** `connected_accounts[]
/// .metadata` has always been on the wire — Steam sends a join date and a game
/// count, Reddit sends karma, Twitter sends posts and followers — and the
/// decoder dropped it, so a linked account here was a name and nothing else
/// while Discord's showed a small biography.
///
/// A row rather than a chip, because a chip has no second line. The chips are
/// still right on the small card, where there is no room for one.
struct ProfileConnectionsSlab: View {
    var connections: [ConnectedAccount]
    var ground: ProfileGround

    var body: some View {
        ProfileSlab(title: "Connections", ground: ground) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                ForEach(connections) { connection in
                    ConnectionRow(connection: connection)
                }
            }
        }
    }
}

/// One linked account: the brand, the name, and the service's own facts.
struct ConnectionRow: View {
    var connection: ConnectedAccount

    @Environment(\.openURL) private var openURL
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var didCopy = false
    @State private var copyReset: Task<Void, Never>?

    private var serviceName: String {
        BrandMark.mark(for: connection.service)?.name ?? connection.service.capitalized
    }

    private var url: URL? { connection.profileURL }

    var body: some View {
        Button(action: act) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                ConnectionMark(service: connection.service, side: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(connection.name)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                        if connection.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.affirmative)
                        }
                        Image(systemName: affordance)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(InkColor.tertiary)
                            .opacity(isHovering ? 1 : 0.45)
                    }
                    facts
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: didCopy)
        .help(helpText)
        .accessibilityLabel(Text("\(serviceName), \(connection.name)"))
        .onDisappear { copyReset?.cancel() }
    }

    /// The line under the name. Absent for the services that publish nothing,
    /// which is most of them — and an empty line reserved for them would put a
    /// ragged gap through the whole list.
    @ViewBuilder
    private var facts: some View {
        let facts = connection.facts
        if !facts.isEmpty {
            FlowLayout(spacing: Spacing.base) {
                ForEach(facts) { fact in
                    switch fact.content {
                    case .since(let date):
                        Text("Member since \(date.formatted(.dateTime.month(.abbreviated).year()))")
                            .font(.system(size: 11))
                            .foregroundStyle(InkColor.tertiary)
                    case .count(let value, let noun):
                        HStack(spacing: 3) {
                            Text(value, format: .number)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(InkColor.secondary)
                            Text(noun)
                                .font(.system(size: 11))
                                .foregroundStyle(InkColor.tertiary)
                        }
                    case .flag(let label):
                        Text(label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(InkColor.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                }
            }
        }
    }

    private var affordance: String {
        if didCopy { return "checkmark" }
        return url == nil ? "doc.on.doc" : "arrow.up.forward"
    }

    private var helpText: String {
        if didCopy { return "Copied" }
        return url == nil ? "Copy \(serviceName) name" : "Open on \(serviceName)"
    }

    private func act() {
        if let url {
            openURL(url)
            return
        }
        AppModel.copy(connection.name)
        didCopy = true
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
