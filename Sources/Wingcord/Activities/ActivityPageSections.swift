import SwiftUI
import WingcordCore

// MARK: - The sections an app's own page carries
//
// **Every one of these was already on the wire and drawn by nothing.** The app
// route answers `install_params`, `flags`, `guild` and
// `directory_entry.detailed_description` / `popular_application_commands` on
// every request this client already makes; the page showed a paragraph and a
// list of links. Captured in `fmbot.har` and `OwO bot.har`, and the two of them
// between them exercise both ends of each section — .fmbot has eight
// permissions, two data-access rows and five commands, OwO has nine, one and
// five.
//
// **Each is absent, never empty.** An app that names no support server has no
// support-server card; one that asks for no permissions has no permission list.
// A heading over nothing is a heading that says the page is broken.

/// The developer's long-form copy, under "Overview".
///
/// **Markdown, through the app's own renderer.** `detailed_description` is
/// written with bullets, bold and inline code — `.fmbot`'s is nine lines of
/// them — and a plain `Text` draws the asterisks. `ProseText` is what every
/// other bio-shaped surface here uses.
///
/// **Collapsed past a measure, with the control saying which way it goes.**
/// Discord's own page clamps it and offers "Show more"; the copy runs to two
/// thousand characters and the page has five sections under it.
struct AppOverviewSection: View {
    var markdown: String

    @Environment(\.motion) private var motion
    @Environment(AppModel.self) private var model: AppModel?
    @State private var isExpanded = false

    /// How tall the collapsed measure is. Roughly eight lines of subheadline,
    /// which is where Discord's own clamp falls.
    private static let collapsedHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            AppSectionHeading("Overview")
            ProseText(
                markdown: markdown,
                font: .system(.subheadline),
                // `ProseText` wants a concrete `Color`; `Ink` is a hierarchical
                // style. `InkColor` is the same ramp as colours.
                color: InkColor.secondary,
                emojiSide: 16,
                onLink: model.map { model in { model.openLink($0) } }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: isExpanded ? nil : Self.collapsedHeight, alignment: .top)
            .clipped()
            if !isExpanded {
                Button("Show more") { isExpanded = true }
                    .buttonStyle(.plain)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
        }
        .animation(motion.standard, value: isExpanded)
    }
}

/// The five Discord lists under "Popular Slash Commands".
///
/// **A description, not a control.** There is no channel behind this page, so a
/// row that offered to run one would be the inert control §5.5 forbids — the
/// command list further down the page makes the same call for the same reason.
struct AppPopularCommands: View {
    var commands: [ApplicationCommand]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            AppSectionHeading("Popular Slash Commands")
            VStack(alignment: .leading, spacing: Spacing.snug) {
                ForEach(commands) { command in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
                        Text("/\(command.name)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Ink.primary)
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, 3)
                            .background(Palette.hoverFill, in: .capsule)
                        Text(command.summary)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSectionPanel()
        }
    }
}

/// What the app asks for when it is added to a server.
///
/// **Named from the app's own catalog**, so the words are the ones the role
/// editor uses — `PermissionCatalog` is the single copy of that, and a second
/// table here would drift from it the first time Discord renamed a bit.
/// A bit this client has no name for is dropped rather than printed as a number.
struct AppPermissionsSection: View {
    var permissions: Permissions

    /// Three columns at this width, which is what the page's measure holds and
    /// what Discord draws.
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: Spacing.base)]

    private var granted: [PermissionCatalog.Entry] {
        PermissionCatalog.groups
            .flatMap(\.entries)
            .filter { permissions.contains($0.permission) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            AppSectionHeading("Permissions")
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text("Required Permissions")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.base) {
                    ForEach(granted) { entry in
                        Label {
                            Text(entry.title)
                                .font(Typeface.rowSubtitle)
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "checkmark")
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(Palette.presenceOnline)
                        }
                    }
                }
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSectionPanel()
        }
    }
}

/// What the app can read once it is in a server.
///
/// The three privileged gateway intents, in Discord's own words — see
/// `AppDataAccess`, which is where the two bits per intent are read.
struct AppDataAccessSection: View {
    var access: [AppDataAccess]
    var privacyPolicyURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            AppSectionHeading("Data Access")
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text("This app can access the following data in the server:")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                ForEach(access) { row in
                    HStack(alignment: .top, spacing: Spacing.snug) {
                        Image(symbol: row.symbolName)
                            .font(.system(.callout))
                            .foregroundStyle(Ink.tertiary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(Ink.primary)
                            Text(row.detail)
                                .font(Typeface.rowSubtitle)
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let privacyPolicyURL {
                    Divider().overlay(Ink.quaternary)
                    // **The developer's own policy, and only where they named
                    // one.** Discord's page links it in this sentence; an app
                    // that declares none gets the sentence without the link
                    // rather than a link that goes nowhere.
                    HStack(spacing: Spacing.tight) {
                        Text("For more about this app's privacy practices, see the")
                            // **On the Text, not the row.** A `foregroundStyle`
                            // on the stack wins over a `Link`'s own tint, which
                            // drew the one thing on the line meant to look
                            // pressable in the same grey as the sentence.
                            .foregroundStyle(Ink.tertiary)
                        Link("privacy policy", destination: privacyPolicyURL)
                            .tint(Palette.accent)
                    }
                    .font(Typeface.rowSubtitle)
                }
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSectionPanel()
        }
    }
}

/// The app's own support server, as a card.
///
/// **The whole guild arrives on the app's route**, so this needs no second
/// fetch — name, icon, description, artwork and both counts. Pressing it opens
/// the same preview a discovery card opens, which is the one thing this client
/// can honestly do with a server the reader is not in.
struct AppSupportServerCard: View {
    var guild: AppSupportGuild
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var shape: RoundedRectangle {
        .rect(cornerRadius: Radius.card, style: .continuous)
    }

    /// `home_header` first — the newer field and the one Discord draws — then
    /// the two splashes. Three different CDN paths, not variants of one.
    private var artworkURL: URL? {
        if let hash = guild.headerHash {
            return CDN.guildHomeHeader(guildID: guild.id, hash: hash, width: 320)
        }
        if let hash = guild.discoverySplashHash {
            return CDN.guildDiscoverySplash(guildID: guild.id, hash: hash, width: 320)
        }
        return guild.splashHash.flatMap {
            CDN.guildSplash(guildID: guild.id, hash: $0, width: 320)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            AppSectionHeading("Support Server")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Palette.surfaceRaised)
                        .frame(height: 96)
                        .overlay {
                            if artworkURL != nil {
                                RemoteImage(url: artworkURL, side: 320, bucket: .artwork) {
                                    Color.clear
                                }
                                .scaledToFill()
                            }
                        }
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            RemoteImage(url: iconURL, side: 44) {
                                Text(guild.monogram)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Ink.secondary)
                                    .frame(width: 44, height: 44)
                                    .background(Palette.surfaceRaised)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Palette.canvas, lineWidth: 2)
                            }
                            .padding(.leading, Spacing.snug)
                            .offset(y: 14)
                        }
                        .padding(.bottom, 14)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(guild.name)
                            // Clear of the mark hanging off the artwork above:
                            // the region's padding reserves the overhang and
                            // nothing else, so the name sat on the icon's edge.
                            .padding(.top, Spacing.tight)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if let description = guild.description {
                            Text(description)
                                .font(Typeface.rowSubtitle)
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Label(
                            "\(guild.memberCount.formatted(.number)) Members",
                            systemImage: "person.fill"
                        )
                        .font(Typeface.metadata)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.bottom, Spacing.snug)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(shape)
                .structuralSurface(in: shape)
                .overlay {
                    shape.strokeBorder(
                        isHovering ? AnyShapeStyle(Ink.tertiary) : AnyShapeStyle(Ink.quaternary),
                        lineWidth: 1
                    )
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .animation(motion.hover, value: isHovering)
            .accessibilityLabel(Text("\(guild.name), the support server"))
        }
    }

    private var iconURL: URL? {
        guild.iconHash.flatMap { CDN.guildIcon(guildID: guild.id, hash: $0, side: 44) }
    }
}

/// Everything short and factual about an app, in one panel.
///
/// **Discord puts these in an aside and this page is one column**, so they are a
/// panel under the overview rather than a rail beside it: a 760-point column
/// with a 240-point aside cut out of it leaves neither half enough for a
/// permission grid or a line of prose. The rows are the same four facts —
/// how many servers, which headings, which languages, and the developer's own
/// links — and each is absent where the route said nothing.
struct AppInformationSection: View {
    var app: ActivityApp
    var openURL: (URL) -> Void

    /// Two columns of facts where the page is wide enough for them, one where
    /// it is not. The languages list is the long one and it takes the full row.
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Spacing.group)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            AppSectionHeading("Information")
            VStack(alignment: .leading, spacing: Spacing.snug) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.snug) {
                    if let count = app.guildCount, count > 0 {
                        fact("Server Count") {
                            Label(
                                "in \(count.formatted(.number.notation(.compactName))) servers",
                                systemImage: "server.rack"
                            )
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                        }
                    }
                    if !app.categoryNames.isEmpty {
                        fact("Categories") {
                            FlowLayout(spacing: Spacing.tight) {
                                ForEach(app.categoryNames, id: \.self) { name in
                                    Text(name)
                                        .font(.system(.caption, weight: .medium))
                                        .foregroundStyle(Ink.secondary)
                                        .padding(.horizontal, Spacing.base)
                                        .padding(.vertical, 3)
                                        .background(Palette.hoverFill, in: .capsule)
                                }
                            }
                        }
                    }
                }
                if !app.languageNames.isEmpty {
                    fact("Supported Languages") {
                        // **Named rather than tagged, and joined the way a
                        // sentence is** — `en-US` is a tag and "English, US" is
                        // what a person reads. Discord draws the first one in
                        // bold; the list is long enough (26 on `.fmbot`) that
                        // one line of prose beats twenty-six chips.
                        Text(app.languageNames.formatted(.list(type: .and)))
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !links.isEmpty {
                    fact("Links") {
                        FlowLayout(spacing: Spacing.snug) {
                            ForEach(links) { link in
                                Button { openURL(link.url) } label: {
                                    Label(link.name, systemImage: symbol(for: link))
                                        .font(Typeface.rowSubtitle)
                                        .foregroundStyle(Palette.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSectionPanel()
        }
    }

    /// **The developer's own first**, because they are the ones somebody came
    /// looking for; the two Discord requires come after. Every address here was
    /// scheme-checked at the wire boundary — see `ExternalLink`.
    private var links: [ExternalLink] {
        var all = app.externalLinks
        if let terms = app.termsOfServiceURL {
            all.append(ExternalLink(name: "Terms of Service", url: terms))
        }
        if let privacy = app.privacyPolicyURL {
            all.append(ExternalLink(name: "Privacy Policy", url: privacy))
        }
        return all
    }

    /// A glyph per link, chosen from the host rather than from the name — a
    /// developer calls the same site "Website", "Official Website" or "Panel",
    /// and the host is the thing that actually says what it is.
    private func symbol(for link: ExternalLink) -> String {
        let host = link.url.host()?.lowercased() ?? ""
        if link.url == app.termsOfServiceURL { return "doc.text" }
        if link.url == app.privacyPolicyURL { return "lock" }
        if host.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if host.contains("discord.gg") || host.contains("discord.com") { return "bubble.left.and.bubble.right" }
        if host.contains("x.com") || host.contains("twitter") || host.contains("bsky") {
            return "bird"
        }
        if host.contains("youtube") || host.contains("youtu.be") { return "play.rectangle" }
        if host.contains("patreon") || host.contains("ko-fi") || host.contains("buymeacoffee") {
            return "cup.and.saucer"
        }
        return "link"
    }

    private func fact(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The page's own vocabulary

/// One section's heading. The page has five of them and they must not drift.
struct AppSectionHeading: View {
    var title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(.headline))
            .foregroundStyle(Ink.primary)
    }
}

extension View {
    /// The panel a section's content sits in.
    ///
    /// Structure, not glass: the page is on the opaque reading surface, where a
    /// material has nothing to lens — §4 rule 3, the same call the card around
    /// the whole page makes.
    func appSectionPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        return background(Palette.surfaceRaised.opacity(0.5), in: shape)
            .overlay { shape.strokeBorder(Ink.quaternary, lineWidth: 1) }
    }
}
