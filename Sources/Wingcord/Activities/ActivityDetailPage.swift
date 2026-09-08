import AVKit
import SwiftUI
import WingcordCore

/// One app's own page: its artwork, what it is, and the one control that
/// matters.
///
/// **The hero prefers the video.** An activity's `embedded_activity_config`
/// carries `activity_preview_video_asset_id` — a real `.mp4` at
/// `/app-assets/{app}/store/{asset}.mp4`, probed live — and a still from the
/// directory carousel only where there is no video. A loop of the app being
/// played says more about it in two seconds than the description does, which is
/// the whole reason Discord ships one.
struct ActivityDetailPage: View {
    var applicationID: ApplicationID
    /// Where a command sent from this page would go, and where an activity
    /// launched from it would run.
    ///
    /// **Nil is a real caller: discovery.** The directory is reached from the
    /// rail with no channel in the picture, so there is nowhere for a Launch or
    /// a Send to act — and §5.5 says a control that cannot work must not look
    /// like one that can. With no channel the page is a *description*: the
    /// screenshots, the commands as a read-only list, and Add App. That is
    /// exactly what the reference client's own directory page shows.
    var channelID: ChannelID?
    var onBack: () -> Void
    var onLaunched: () -> Void
    /// Puts a command into the composer with its first option focused. The page
    /// closes behind it — the reader is being sent somewhere to type.
    /// Opens this app's storefront, one page deeper.
    var onOpenStore: () -> Void = {}
    var onFillCommand: (SlashCommand) -> Void = { _ in }
    /// Adds this app to a server. The whole action bar where there is no
    /// channel, and a menu row where there is.
    var onAdd: () -> Void = {}
    /// Opens a neighbour's own page. Nowhere to go in the launcher's flyout,
    /// which is why it defaults to nothing there.
    var onOpenSimilar: (ActivityApp) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isLaunching = false
    /// The row currently posting an interaction, by id. One at a time is not
    /// enforced — a bot answers each independently — but a row has to say which
    /// one the reader pressed.
    @State private var sendingRowID: String?

    private var app: ActivityApp? { model.activityApp(applicationID) }

    var body: some View {
        ZStack(alignment: .top) {
            if let app {
                page(app)
            } else {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            }
            PageChromeBar(onBack: onBack) { overflowMenu }
        }
        .task(id: applicationID) {
            // Sequential: the directory copy is what the page draws first, and
            // the command index is 7,700 bytes that only fills the list below
            // the fold.
            await model.sessionController.loadActivityApp(applicationID)
            await model.sessionController.loadAppCommandIndex(for: applicationID)
            await model.sessionController.loadApplicationStorefrontFlag(applicationID)
            model.sessionController.loadSimilarApps(applicationID)
        }
    }

    private func page(_ app: ActivityApp) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                // **Zero spacing, and the gap is padding on the details.** The
                // icon overhangs the hero's bottom edge, and an overlay takes
                // no space — so a stack gap sized for two boxes puts the title
                // *under* the icon. The clearance has to be measured from the
                // overhang, which is the one number that decides it.
                VStack(alignment: .leading, spacing: 0) {
                    ActivityHero(app: app)
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text(app.name)
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(Ink.primary)
                        chips(app)
                        Text(app.about)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        footnotes(app)
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.top, ActivityHero.overhang + Spacing.base)

                    gallery(app)
                    commandList
                    similar
                }
                .padding(.bottom, Spacing.margin)
            }
            .scrollIndicators(.never)
            .softScrollEdgesVertical()

            launchBar(app)
        }
    }

    // MARK: The gallery

    /// The developer's own screenshots, side by side.
    ///
    /// **A scroll, not a pager.** Discord draws one at a time with arrows and
    /// dots; a horizontal strip shows two at this width, needs no control of its
    /// own, and is what every gallery on this platform does. The first item is
    /// also the hero above — that is Discord's own arrangement, and it is why the
    /// strip is drawn whole rather than dropping its first.
    @ViewBuilder
    private func gallery(_ app: ActivityApp) -> some View {
        if app.gallery.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.base) {
                    ForEach(app.gallery, id: \.self) { url in
                        RemoteImage(url: url, side: Self.galleryWidth, bucket: .artwork) {
                            Palette.surfaceRaised
                        }
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(width: Self.galleryWidth, height: Self.galleryWidth * 9 / 16)
                        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                    }
                }
                .padding(.horizontal, Spacing.snug)
            }
            .scrollIndicators(.never)
            .padding(.top, Spacing.snug)
            .accessibilityLabel(Text("Screenshots"))
        }
    }

    private static let galleryWidth: CGFloat = 260

    // MARK: You might also like

    /// What Discord puts under the page, and it is the same card the directory
    /// grid draws — one definition of "an app in a list", not two.
    @ViewBuilder
    private var similar: some View {
        let neighbours = model.similarDirectoryApps[applicationID] ?? []
        if !neighbours.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("You might also like")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(Ink.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .padding(.leading, Spacing.tight)
                ForEach(neighbours.prefix(Self.similarShown)) { app in
                    DiscoveryAppCard(app: app) { onOpenSimilar(app) }
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.group)
        }
    }

    /// Three, which is what Discord draws. Past that it is a second directory
    /// under the page rather than a suggestion.
    private static let similarShown = 3

    // MARK: The chips

    /// Participants first, then the developer's own tags.
    ///
    /// The participant chip is absent when the app states no limit — thirty-
    /// seven of the captured shelf's seventy-three say nothing at all, and a
    /// chip reading "Unknown" costs a row to say nothing.
    private func chips(_ app: ActivityApp) -> some View {
        // `FlowLayout`, not an `HStack`: five tags at a readable size do not
        // fit one line of a 388pt panel, and it already carries the
        // measure-at-the-proposed-width fix a long tag would otherwise trip.
        FlowLayout(spacing: Spacing.tight) {
            if let participants = app.participantsLabel {
                chip(participants, systemImage: "person.2.fill")
            }
            ForEach(app.tags, id: \.self) { tag in
                chip(tag, systemImage: nil)
            }
        }
    }

    private func chip(_ text: String, systemImage: String?) -> some View {
        HStack(spacing: Spacing.tight) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(.caption2))
            }
            Text(text).font(.system(.caption, weight: .medium))
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .background(Palette.surfaceRaised, in: .capsule)
    }

    /// The things worth knowing before pressing Launch.
    ///
    /// Advertisements first, because it is the only line here that changes
    /// whether somebody wants to open the thing at all.
    @ViewBuilder
    private func footnotes(_ app: ActivityApp) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if app.config?.displaysAdvertisements == true {
                footnote("Shows advertisements", systemImage: "megaphone")
            }
            if app.config?.requiresAgeGate == true {
                footnote("Asks your age before it runs", systemImage: "person.badge.shield.exclamationmark")
            }
            if let count = app.guildCount, count > 0 {
                footnote("In \(Self.compact(count)) servers", systemImage: "server.rack")
            }
            if !app.languageNames.isEmpty {
                footnote(
                    app.languageNames.formatted(.list(type: .and)),
                    systemImage: "character.bubble"
                )
            }
            if app.termsOfServiceURL != nil || app.privacyPolicyURL != nil
                || !app.externalLinks.isEmpty
            {
                policyLinks(app)
            }
        }
        .padding(.top, Spacing.tight)
    }

    private func footnote(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Typeface.rowSubtitle)
            .foregroundStyle(Ink.tertiary)
    }

    private func policyLinks(_ app: ActivityApp) -> some View {
        HStack(spacing: Spacing.base) {
            // **The developer's own first**, because they are the ones somebody
            // came looking for — an FAQ is read and a privacy policy is checked.
            // Their scheme was verified at the wire boundary; see `ExternalLink`.
            ForEach(app.externalLinks) { link in
                Link(link.name, destination: link.url)
            }
            if let terms = app.termsOfServiceURL {
                Link("Terms", destination: terms)
            }
            if let privacy = app.privacyPolicyURL {
                Link("Privacy", destination: privacy)
            }
        }
        .font(Typeface.rowSubtitle)
        .tint(Palette.accent)
    }

    /// Abbreviated the way a count of servers is read rather than counted —
    /// 745,000 is "745K", and the three digits after it are noise.
    private static func compact(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    // MARK: The commands

    /// Everything the application registers, as rows.
    ///
    /// **The trailing control is decided by whether the leaf takes anything.**
    /// A command with no options sends outright; one with options sends the
    /// reader to the composer with the command already in the bar, because
    /// filling `gen eject`'s user is a picker and a picker does not belong in a
    /// 388-point page that is already scrolling.
    @ViewBuilder
    private var commandList: some View {
        let sections = model.appCommandSections(for: applicationID)
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.group) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text(section.title)
                            .font(Typeface.sectionHeader)
                            .foregroundStyle(Ink.secondary)
                            .textCase(.uppercase)
                            .kerning(0.4)
                            .padding(.leading, Spacing.tight)
                        VStack(spacing: Spacing.hair) {
                            ForEach(section.rows) { row in
                                AppCommandRowView(
                                    row: row,
                                    // With no channel there is nowhere to send
                                    // to and no composer to fill, so the list is
                                    // what it looks like: a description of what
                                    // this app can do.
                                    isActionable: channelID != nil,
                                    isSending: sendingRowID == row.id,
                                    onSend: { send(row) },
                                    onFill: {
                                        onFillCommand(row.command)
                                        onLaunched()
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.group)
        }
    }

    private func send(_ row: AppCommandRow) {
        guard let channelID else { return }
        sendingRowID = row.id
        Task {
            await model.sessionController.runCommand(
                PendingCommand(command: row.command),
                in: channelID,
                // Captured: the same command sent from an app's page carries
                // `app_launcher` where the composer's carries `slash_ui`.
                origin: .applicationPage
            )
            sendingRowID = nil
            onLaunched()
        }
    }

    // MARK: The one control

    /// **Absent, not disabled, when the app cannot be launched.**
    ///
    /// A search result may be a bot — no `embedded_activity_config` at all —
    /// and a greyed-out Launch on one implies a permission the reader might
    /// gain. There is none: it is not that kind of app. The bar says so
    /// instead. `INVARIANTS.md` §5.5.
    @ViewBuilder
    private func launchBar(_ app: ActivityApp) -> some View {
        if channelID == nil {
            directoryBar(app)
        } else if app.isLaunchable {
            let entryPoint = model.appEntryPoint(for: applicationID)
            HStack(spacing: Spacing.base) {
                launchButton(app, entryPoint: entryPoint, inDirectMessage: false)
                if canLaunchInDirectMessage(entryPoint) {
                    launchButton(app, entryPoint: entryPoint, inDirectMessage: true)
                }
            }
            .padding(Spacing.snug)
        } else {
            Text("This app can't be opened here")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(Ink.tertiary)
                .frame(maxWidth: .infinity)
                .padding(Spacing.snug)
        }
    }

    /// What an app's page offers when it is reached from the directory.
    ///
    /// **Launch, Add App and a link** — the reference client's own three, and the
    /// overflow above already carries the fourth. The one that needed thinking
    /// about is Launch: there is no channel here, so the ordinary launch has
    /// nowhere to run. `launchActivityInDirectMessage` does — into the app's own
    /// conversation — and it is offered exactly where the entry point declares
    /// the `BOT_DM` context and nowhere else. An app that cannot be launched in a
    /// DM shows no Launch rather than a greyed one: §5.5, and the reason given
    /// where `canLaunchInDirectMessage` is defined.
    @ViewBuilder
    private func directoryBar(_ app: ActivityApp) -> some View {
        let entryPoint = model.appEntryPoint(for: applicationID)
        HStack(spacing: Spacing.base) {
            Spacer(minLength: 0)
            if app.isLaunchable, canLaunchInDirectory(entryPoint) {
                Button {
                    isLaunching = true
                    Task {
                        await model.sessionController.launchActivityInDirectMessage(app)
                        isLaunching = false
                        onLaunched()
                    }
                } label: {
                    Group {
                        if isLaunching {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Launch", systemImage: "play.fill")
                        }
                    }
                    .frame(minWidth: 96)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(isLaunching)
            }
            Button("Add App", systemImage: "plus.app") { onAdd() }
                .buttonStyle(.glass)
                .controlSize(.large)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.directoryURL(applicationID), forType: .string)
            } label: {
                Image(systemName: "link")
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Copy a link to this app")
            .accessibilityLabel(Text("Copy a link to this app"))
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
    }

    /// Whether Launch can work with no channel.
    ///
    /// The `BOT_DM` half of `canLaunchInDirectMessage`, without the "am I
    /// already in that conversation" half — which is a question about a channel
    /// this page does not have.
    private func canLaunchInDirectory(_ entryPoint: ActivityEntryPoint?) -> Bool {
        entryPoint?.contexts.contains(Self.botDirectMessageContext) ?? false
    }

    /// The address Discord's own directory page lives at.
    nonisolated static func directoryURL(_ id: ApplicationID) -> String {
        "https://discord.com/discovery/applications/\(id.rawValue)"
    }

    /// **The entry point's own name is the button's words.** Dank Memer's is
    /// called `GRIND XP` and that is exactly what Discord draws — the label is
    /// the command's `name` and nothing more, which the capture settles: the
    /// interaction it posts carries `"name": "GRIND XP"` at both levels.
    /// "Launch" is the fallback for an app whose entry point is in the account
    /// index rather than its own, where this page cannot see it.
    ///
    /// **Only the first character is raised.** A command name is lowercase on
    /// the wire — Watch Together's entry point is literally `launch` — and
    /// Discord draws it capitalised. `.capitalized` would do it by *word* and
    /// turn Dank Memer's `GRIND XP` into `Grind Xp`, so the rest of the name is
    /// left exactly as its developer wrote it.
    private func launchLabel(_ entryPoint: ActivityEntryPoint?) -> String {
        guard let name = entryPoint?.name, !name.isEmpty else { return "Launch" }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// **Whether the app runs in a direct message, from its own `contexts`.**
    /// `1` is `BOT_DM`. Dank Memer's entry point carries `[0, 1, 2]` and its
    /// page draws "Launch in DM"; an app that only lists `0` runs in servers and
    /// has nowhere to put a second button.
    ///
    /// Hidden rather than disabled when the app cannot: a greyed-out control
    /// implies a permission that could be gained, and this is not that kind of
    /// limit. `INVARIANTS.md` §5.5.
    private func canLaunchInDirectMessage(_ entryPoint: ActivityEntryPoint?) -> Bool {
        guard let channelID else { return false }
        guard let entryPoint, entryPoint.contexts.contains(Self.botDirectMessageContext) else {
            return false
        }
        // In the bot's own DM already, "Launch in DM" is the button beside it.
        return model.channelIndex[channelID]?.recipientIDs
            != [UserID(rawValue: applicationID.rawValue)]
    }

    /// `BOT_DM` in Discord's interaction-context enum.
    private static let botDirectMessageContext = 1

    private func launchButton(
        _ app: ActivityApp,
        entryPoint: ActivityEntryPoint?,
        inDirectMessage: Bool
    ) -> some View {
        Button {
            isLaunching = true
            Task {
                if inDirectMessage {
                    await model.sessionController.launchActivityInDirectMessage(app)
                } else if let channelID {
                    await model.sessionController.launchActivity(
                        app,
                        in: channelID,
                        section: model.activityQuery.isEmpty ? nil : "Search"
                    )
                }
                isLaunching = false
                onLaunched()
            }
        } label: {
            Group {
                if isLaunching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(inDirectMessage ? "Launch in DM" : launchLabel(entryPoint))
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // The accent is reserved for the primary action. A second button beside
        // it in the same colour is two primaries, which is none.
        .foregroundStyle(inDirectMessage ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(.white))
        .modifier(LaunchButtonChrome(isSecondary: inDirectMessage))
        .disabled(isLaunching)
    }

    /// Over the artwork, so it takes `.clear` glass — the picture passes under
    /// it and lenses rather than being frosted away.
    /// Everything about the app that is not "run it".
    ///
    /// **Open Store is gated on `storefront_available`**, which arrives on the
    /// application object itself — so the row is offered on Discord's own answer
    /// rather than on a flag that implies one, and an app with no store never
    /// shows a row that opens onto nothing. `INVARIANTS.md` §5.5.
    ///
    /// There is no "Manage App": managing one is the developer portal, which is
    /// a website and not a surface this client has.
    private var overflowMenu: some View {
        Menu {
            if model.applicationHasStorefront(applicationID) {
                Button("Open Store", systemImage: "bag") { onOpenStore() }
            }
            Button("Add App", systemImage: "plus.app") { onAdd() }
            Divider()
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.directoryURL(applicationID), forType: .string)
            }
            Button("Copy App ID", systemImage: "number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(applicationID.description, forType: .string)
            }
        } label: {
            // **The glass goes on the LABEL, not on the `Menu`.** A `Menu` lays
            // its label out itself and hands the modifiers outside it a
            // different box, so chrome applied there drew nothing at all — the
            // glyph sat in the right place with no circle behind it while the
            // back button beside it had one. Both controls are now the same
            // view, which is the only way to guarantee they match.
            PageChromeCircle { Image(systemName: "ellipsis") }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }
}

/// One circular control over a page's artwork.
///
/// The single definition both ends of `PageChromeBar` are built from — a back
/// arrow and a menu that must be the same size, the same material and the same
/// ink, and were not while each drew its own.
struct PageChromeCircle<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(Typeface.controlGlyph)
            .foregroundStyle(Ink.primary)
            .frame(width: Metrics.control, height: Metrics.control)
            .contentShape(.circle)
            .interactiveChromeOverMedia(in: .circle)
    }
}

/// The controls that float over a page's artwork: one way back, and whatever
/// that page hangs at the other end.
///
/// **The bar does the layout, never the control inside it.** `BackControl` used
/// to carry its own `Spacer` and padding, so composing it into a row put a
/// full-width control beside the thing that was meant to sit at the far end —
/// and pushed that thing off the edge.
struct PageChromeBar<Trailing: View>: View {
    var onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button(action: onBack) {
                PageChromeCircle { Image(systemName: "chevron.backward") }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Spacer(minLength: 0)
            trailing
        }
        .padding(Spacing.snug)
    }
}

/// The one way back, with nothing at the other end.
struct BackControl: View {
    var action: () -> Void

    var body: some View {
        PageChromeBar(onBack: action) { EmptyView() }
    }
}

// MARK: - The hero

/// The looping preview, or the carousel's first still, or the tile artwork.
///
/// **Muted, looping, and paused under Reduce Motion.** A silent loop is what
/// this is for — it is a picture that moves, not a video somebody chose to
/// play — and under Reduce Motion it holds its first frame instead, which is
/// the still it would otherwise have shown.
private struct ActivityHero: View {
    var app: ActivityApp

    /// How far the icon hangs below the artwork.
    ///
    /// **Read by the page above to size its own top padding**, because an
    /// overlay contributes no height and nothing else can know how far down the
    /// icon reaches. A third of the icon is the proportion that leaves the mark
    /// clearly attached to the picture while still standing clear of it.
    /// `nonisolated` because the alignment guide that applies it is a
    /// `Sendable` closure: the target defaults every declaration to the main
    /// actor, and a guide runs wherever layout does.
    nonisolated static let overhang = Metrics.activityHeaderIcon / 3

    @Environment(\.motion) private var motion

    private var videoURL: URL? {
        app.config?.previewVideoAssetID.flatMap {
            CDN.activityPreviewVideo(id: app.id, assetID: $0)
        }
    }

    private var stillURL: URL? {
        app.heroImageURL
            ?? app.tileAssetID.flatMap {
                CDN.applicationAsset(id: app.id, assetID: $0, side: ActivityLauncher.width)
            }
    }

    /// The tallest this is ever drawn.
    ///
    /// **A ceiling, because a ratio alone has none.** `aspectRatio(16/9)` is a
    /// height *derived from the width*, and this page was written for a 388-point
    /// flyout where that is 218 points. Put in discovery's own column it became a
    /// thousand-point banner with the app's name below the fold — the picture was
    /// not wrong, it was simply given a width nothing had capped. The page's own
    /// measure fixes it too; this is the belt, because a hero is the one element
    /// here whose height is somebody else's arithmetic.
    private static let maximumHeight: CGFloat = 240


    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: Self.maximumHeight)
            .overlay {
                if let videoURL, !motion.reduceMotion {
                    LoopingVideo(url: videoURL)
                } else if stillURL != nil {
                    RemoteImage(url: stillURL, side: ActivityLauncher.width, bucket: .artwork) {
                        Palette.surfaceRaised
                    }
                    .aspectRatio(contentMode: .fill)
                } else {
                    Palette.surfaceRaised
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                // The icon rides the seam, half on the artwork and half off it —
                // the same anchoring an app's own page uses everywhere, and it
                // is what ties the mark to the picture rather than floating it.
                ActivityIcon(
                    row: AppModel.row(for: app),
                    side: Metrics.activityHeaderIcon
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: Metrics.activityHeaderIcon * 0.28,
                        style: .continuous
                    )
                    .strokeBorder(Palette.hoverFill, lineWidth: 1)
                }
                .padding(.leading, Spacing.snug)
                .alignmentGuide(.bottom) { $0[.bottom] - Self.overhang }
            }
    }
}

// MARK: - One command on an app's page

/// `gen eject`, its description, and the one control that fits it.
///
/// **Send or a chevron, never both and never neither.** Both captures agree on
/// every row: a leaf with no options draws Send and runs outright; a leaf that
/// takes one draws a chevron and hands the command to the composer. Nothing else
/// separates them.
private struct AppCommandRowView: View {
    var row: AppCommandRow
    /// Whether pressing the row does anything.
    ///
    /// **False in the directory, where there is no channel to act in.** The row
    /// stays legible and stops being a control — not `.disabled`, which would
    /// take the description's contrast with it for a row that is doing its job
    /// perfectly well as a *description*. §5.5: remove the affordance, not the
    /// legibility.
    var isActionable = true
    var isSending: Bool
    var onSend: () -> Void
    var onFill: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: row.sendsImmediately ? onSend : onFill) {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.command.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if !row.command.summary.isEmpty {
                        Text(row.command.summary)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.base)
                control
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.base)
            .background(
                isHovered ? Palette.hoverFill : .clear,
                in: .rect(cornerRadius: Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isActionable)
        // Guarded rather than written unconditionally — §2. A tracking area on
        // a row that cannot be pressed is geometry AppKit re-derives for nothing.
        .onHover { if isActionable, isHovered != $0 { isHovered = $0 } }
        .animation(motion.hover, value: isHovered)
        .disabled(isSending)
        .accessibilityLabel(Text(row.command.name))
        .accessibilityAddTraits(isActionable ? .isButton : [])
        .accessibilityHint(Text(
            !isActionable ? "" :
                row.sendsImmediately ? "Runs this command" : "Opens this command in the composer"
        ))
    }

    @ViewBuilder
    private var control: some View {
        if !isActionable {
            // Nothing at all. A row that is a description has no trailing mark,
            // and a greyed Send would be the control §5.5 forbids.
            EmptyView()
        } else if isSending {
            ProgressView().controlSize(.small)
        } else if row.sendsImmediately {
            // A filled pill rather than a bare glyph: it is the only thing on
            // the row that *does* something, and the chevron beside it on the
            // next row means something different.
            HStack(spacing: Spacing.tight) {
                Text("Send").font(.system(.caption, weight: .semibold))
                Image(systemName: "paperplane.fill").font(.system(.caption2))
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .background(Palette.selectionFill, in: .capsule)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
        }
    }
}

/// The launch bar's two weights.
///
/// A modifier rather than a branch at the call site, because `.emphasisChrome`
/// and `.chromeOverMedia` return different opaque types and a `ViewBuilder`
/// `if` around them makes the button's identity change with the branch — which
/// is what makes SwiftUI drop its press state mid-press.
private struct LaunchButtonChrome: ViewModifier {
    var isSecondary: Bool

    func body(content: Content) -> some View {
        if isSecondary {
            content.chromeOverMedia(in: .capsule)
        } else {
            content.emphasisChrome(Palette.accent)
        }
    }
}
