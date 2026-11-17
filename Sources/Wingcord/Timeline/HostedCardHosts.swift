import AppKit
import SwiftUI
import WingcordCore

/// Keeps a live card over every profile link and event card in view.
///
/// **Hosted rather than drawn, and only these.** Discord's user profile embed
/// is the app's own profile card — the styled name, the badges, the avatar's
/// decoration, the effect playing over it and the frame around it — and its
/// event embed is the events panel's own parts; each is a component another
/// surface already draws. Drawing them a second time in Core Graphics would be
/// a second copy of all of them to keep in step; these links are rare enough
/// in a transcript that one hosted card per link in view costs nothing a
/// reader could measure.
///
/// **Only what is in view, and a screen either side.** Cards are mounted as the
/// rows carrying them approach and taken down as they leave, so a channel with
/// a hundred profile links scrolled past holds the handful on screen. They are
/// subviews of the canvas, whose bounds already scroll with the document, so a
/// card moves with its row without being told.
@MainActor
final class HostedCardHosts {
    /// What marks a card among the canvas's subviews — for its accessibility
    /// children, which list the cards beside the rows they draw.
    static let identifier = NSUserInterfaceItemIdentifier("HostedCard")

    private var hosts: [HostedCardPlacement.ID: NSHostingView<HostedCardRoot>] = [:]

    /// Mounts the cards `canvas` has in `visible` (widened by a screen each
    /// way), moves the ones whose rows moved, and takes down the rest.
    func reconcile(in canvas: TimelineCanvasView, visible: CGRect, model: AppModel) {
        let reach = visible.insetBy(dx: 0, dy: -max(visible.height, 400))
        let placements = canvas.hostedCardPlacements(in: reach)
        var kept = Set<HostedCardPlacement.ID>()
        for placement in placements {
            kept.insert(placement.id)
            if let host = hosts[placement.id], host.rootView.key == placement.key {
                if host.frame != placement.frame { host.frame = placement.frame }
                continue
            }
            hosts[placement.id]?.removeFromSuperview()
            let host = NSHostingView(rootView: HostedCardRoot(key: placement.key, model: model))
            // The canvas places it; the card must not resize itself or ask
            // the canvas for room it was not given.
            host.sizingOptions = []
            host.identifier = Self.identifier
            host.frame = placement.frame
            canvas.addSubview(host)
            hosts[placement.id] = host
        }
        for (id, host) in hosts where !kept.contains(id) {
            host.removeFromSuperview()
            hosts[id] = nil
        }
    }

    /// Takes every card down — the transcript is going away or changing
    /// channel.
    func removeAll() {
        for host in hosts.values { host.removeFromSuperview() }
        hosts.removeAll()
    }

    /// What a card measures before it is ever on screen, so the row can
    /// reserve its space on the layout that first draws it — an event card at
    /// Discord's widest, which a narrower column then corrects.
    static func measure(_ key: HostedCardKey, model: AppModel) -> CGSize {
        let root = HostedCardRoot(key: key, model: model, isMeasuring: true)
        switch key {
        case .user:
            return NSHostingView(rootView: root).fittingSize
        case .event, .plaintext, .activity:
            return NSHostingView(rootView: root.frame(width: Metrics.embedMaxWidth)).fittingSize
        case .spotify:
            return CGSize(width: Metrics.embedMaxWidth, height: SpotifyLinkCard.height)
        case .contentEntry:
            return CGSize(width: Metrics.embedMaxWidth, height: ActivityEntryCard.height)
        }
    }
}

/// The root of one hosted card: the card, with the environment every window
/// root gives its views.
struct HostedCardRoot: View {
    var key: HostedCardKey
    var model: AppModel
    /// A card laid out only to learn its size. See `MiniProfileCard.showsEffect`.
    var isMeasuring = false

    var body: some View {
        Group {
            switch key {
            case .user(let user): UserLinkCard(key: user, isMeasuring: isMeasuring)
            case .event(let event): EventLinkCard(key: event, isMeasuring: isMeasuring)
            case .plaintext(let file): PlaintextPreviewCard(key: file, isMeasuring: isMeasuring)
            case .activity(let activity): ActivityLinkCard(key: activity, isMeasuring: isMeasuring)
            case .spotify(let spotify): SpotifyLinkCard(key: spotify)
            case .contentEntry(let entry): ActivityEntryCard(key: entry)
            }
        }
        .resolvesMotion()
        .environment(model)
    }
}

/// Discord's user profile embed: the app's own profile card, in its embed form
/// — 300 wide, Discord's width (`.sm{--custom-user-profile-embed-width:300px}`).
///
/// **It reports its own size**, because it can change after it is drawn: the
/// profile, its effect and its frame arrive separately, and a frame hangs
/// artwork outside the card that the row has to make room for.
struct UserLinkCard: View {
    var key: UserCardKey
    var isMeasuring = false

    static let width: CGFloat = 300

    @Environment(AppModel.self) private var model

    var body: some View {
        if let profile = model.profilePresentation(for: ProfileRequest(
            userID: key.userID,
            guildID: key.guildID,
            // A link in a direct message is the account's own profile; nil
            // would fall back to whichever server happens to be selected.
            showsMainProfile: key.guildID == nil,
            anchor: .zero
        )) {
            MiniProfileCard(
                profile: profile,
                openFullProfile: { model.openProfile(key.userID, anchor: .zero, depth: .full, tab: $0) },
                width: Self.width,
                form: .embed,
                showsEffect: !isMeasuring
            )
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                // A measuring card reports through its caller, once.
                guard !isMeasuring else { return }
                model.noteHostedCardSize(size, for: .user(key))
            }
        }
    }
}
