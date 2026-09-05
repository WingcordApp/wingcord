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

// MARK: - Connections

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
