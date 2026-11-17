import SwiftUI
import WingcordCore

/// An activity link as Discord draws it (Alex, 2026-11-17, his Image 25): the
/// app's cover across the top, its icon, name, the developer's tags and how
/// many can play, and Play, which starts it here.
///
/// **Wingcord's touches on Discord's arrangement**: the cover plays the app's
/// own preview loop while the pointer rests on it (where moving pictures are
/// allowed), fades into the card rather than stopping at a line, and the card
/// lifts a little under the pointer. As wide as its column, up to 432.
struct ActivityLinkCard: View {
    var key: ActivityCardKey
    var isMeasuring = false

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var settings = AppSettings.shared

    private static let corner: CGFloat = 16
    private static let coverAspect: CGFloat = 432 / 216

    var body: some View {
        if let app = model.activityApp(key.applicationID) {
            card(app)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    guard !isMeasuring else { return }
                    model.noteHostedCardSize(size, for: .activity(key))
                }
        }
    }

    private func card(_ app: ActivityApp) -> some View {
        VStack(spacing: 0) {
            cover(app)
            VStack(alignment: .leading, spacing: Spacing.snug) {
                HStack(alignment: .center, spacing: Spacing.snug) {
                    RemoteImage(url: model.applicationIconURL(app.id, side: 64), side: 64) {
                        Palette.surface
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if !app.tags.isEmpty {
                            Text(app.tags.prefix(3).joined(separator: " \u{2022} "))
                                .font(.system(.callout))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                        }
                        if let players = Self.players(app.maxParticipants) {
                            Label(players, systemImage: "person.fill")
                                .font(.system(.callout))
                                .foregroundStyle(Ink.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    Spacer(minLength: 0)
                }
                playButton(app)
            }
            .padding(Spacing.margin)
        }
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Self.corner, style: .continuous))
        .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1)
        }
        .scaleEffect(isHovering && !motion.reduceMotion ? 1.008 : 1)
        .onHover { isHovering = $0 }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(app.name))
    }

    private func cover(_ app: ActivityApp) -> some View {
        Color.clear
            .aspectRatio(Self.coverAspect, contentMode: .fit)
            .overlay {
                RemoteImage(url: model.activityCoverURL(app.id), side: 432, bucket: .artwork) {
                    ZStack {
                        Palette.surface
                        RemoteImage(url: model.applicationIconURL(app.id, side: 96), side: 96) { Color.clear }
                            .frame(width: 96, height: 96)
                            .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    }
                }
                .aspectRatio(contentMode: .fill)
            }
            .overlay {
                // The app's own loop, only while the pointer is on the card.
                if isHovering, !isMeasuring, settings.playsAnimatedMedia, !motion.reduceMotion,
                   let video = app.config?.previewVideoAssetID.flatMap({ CDN.activityPreviewVideo(id: app.id, assetID: $0) }) {
                    LoopingVideo(url: video)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                // The cover settles into the card instead of ending at a line.
                LinearGradient(
                    colors: [.clear, Palette.surfaceRaised.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 36)
            }
            .clipped()
    }

    private func playButton(_ app: ActivityApp) -> some View {
        let isStarting = model.activityStarting?.applicationID == app.id
        return Button {
            Task { await model.sessionController.startActivity(app, in: key.channelID, section: "activity_link") }
        } label: {
            HStack(spacing: Spacing.tight) {
                if isStarting { ProgressView().controlSize(.small) }
                Text(isStarting ? "Starting\u{2026}" : "Play")
            }
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isStarting || !app.isLaunchable)
        .help(app.isLaunchable ? "Play \(app.name) here" : "\(app.name) can\u{2019}t be launched here")
    }

    /// Discord's words: "Unlimited Players", "1-8 Players".
    static func players(_ count: Int?) -> String? {
        guard let count else { return nil }
        if count < 0 { return "Unlimited Players" }
        return count > 1 ? "1-\(count) Players" : nil
    }
}
