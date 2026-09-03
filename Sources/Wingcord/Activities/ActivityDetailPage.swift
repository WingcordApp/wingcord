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
    var channelID: ChannelID
    var onBack: () -> Void
    var onLaunched: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isLaunching = false

    private var app: ActivityApp? { model.activityApp(applicationID) }

    var body: some View {
        ZStack(alignment: .top) {
            if let app {
                page(app)
            } else {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            }
            backButton
        }
        .task(id: applicationID) {
            await model.sessionController.loadActivityApp(applicationID)
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
                }
                .padding(.bottom, Spacing.margin)
            }
            .scrollIndicators(.never)
            .softScrollEdgesVertical()

            launchBar(app)
        }
    }

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
            if app.termsOfServiceURL != nil || app.privacyPolicyURL != nil {
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

    // MARK: The one control

    /// **Absent, not disabled, when the app cannot be launched.**
    ///
    /// A search result may be a bot — no `embedded_activity_config` at all —
    /// and a greyed-out Launch on one implies a permission the reader might
    /// gain. There is none: it is not that kind of app. The bar says so
    /// instead. `INVARIANTS.md` §5.5.
    @ViewBuilder
    private func launchBar(_ app: ActivityApp) -> some View {
        if app.isLaunchable {
            Button {
                isLaunching = true
                Task {
                    await model.sessionController.launchActivity(
                        app,
                        in: channelID,
                        section: model.activityQuery.isEmpty ? nil : "Search"
                    )
                    isLaunching = false
                    onLaunched()
                }
            } label: {
                Group {
                    if isLaunching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Launch").font(.system(.subheadline, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.control)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .emphasisChrome(Palette.accent)
            .disabled(isLaunching)
            .padding(Spacing.snug)
        } else {
            Text("This app can't be opened here")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(Ink.tertiary)
                .frame(maxWidth: .infinity)
                .padding(Spacing.snug)
        }
    }

    /// Over the artwork, so it takes `.clear` glass — the picture passes under
    /// it and lenses rather than being frosted away.
    private var backButton: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(Typeface.controlGlyph)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.primary)
            .interactiveChromeOverMedia(in: .circle)
            .accessibilityLabel("Back to apps")
            Spacer()
        }
        .padding(Spacing.snug)
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

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let videoURL, !motion.reduceMotion {
                    ActivityPreviewVideo(url: videoURL)
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

/// A silent, looping preview.
///
/// `AVPlayerLayer` through a representable rather than `VideoPlayer`: the
/// SwiftUI view brings transport controls, and there is nothing here to
/// control. It is a moving picture.
private struct ActivityPreviewVideo: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.play(url)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.play(url)
    }

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        // Without this the player keeps its decoder and its network connection
        // alive after the page is gone — and this page is opened and left
        // constantly, once per app somebody looks at.
        view.stop()
    }

    final class PreviewView: NSView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var current: URL?

        override var isFlipped: Bool { true }

        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

        func play(_ url: URL) {
            guard current != url else { return }
            current = url
            stop()

            wantsLayer = true
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            // The preview is decoration; it must never duck a call or take the
            // audio session. Muted is not enough on its own — a player with
            // audio still claims one.
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            // `AVPlayerLooper` rather than an end-of-item notification: the
            // notification path shows a black frame at the seam.
            looper = AVPlayerLooper(player: player, templateItem: item)
            (layer as? AVPlayerLayer)?.player = player
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
            player.play()
            self.player = player
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            (layer as? AVPlayerLayer)?.player = nil
        }
    }
}
