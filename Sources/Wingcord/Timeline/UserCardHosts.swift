import AppKit
import SwiftUI
import WingcordCore

/// Keeps a live profile card over every profile link in view.
///
/// **Hosted rather than drawn, and only these.** Discord's user profile embed
/// is the app's own profile card — the styled name, the badges, the avatar's
/// decoration, the effect playing over it and the frame around it — and each
/// of those is a component the profile surfaces already draw. Drawing them a
/// second time in Core Graphics would be a second copy of all of them to keep
/// in step; a profile link is rare enough in a transcript that one hosted card
/// per link in view costs nothing a reader could measure.
///
/// **Only what is in view, and a screen either side.** Cards are mounted as the
/// rows carrying them approach and taken down as they leave, so a channel with
/// a hundred profile links scrolled past holds the handful on screen. They are
/// subviews of the canvas, whose bounds already scroll with the document, so a
/// card moves with its row without being told.
@MainActor
final class UserCardHosts {
    private var hosts: [UserCardPlacement.ID: NSHostingView<UserLinkCardHost>] = [:]

    /// Mounts the cards `canvas` has in `visible` (widened by a screen each
    /// way), moves the ones whose rows moved, and takes down the rest.
    func reconcile(in canvas: TimelineCanvasView, visible: CGRect, model: AppModel) {
        let reach = visible.insetBy(dx: 0, dy: -max(visible.height, 400))
        let placements = canvas.userCardPlacements(in: reach)
        var kept = Set<UserCardPlacement.ID>()
        for placement in placements {
            kept.insert(placement.id)
            if let host = hosts[placement.id], host.rootView.key == placement.key {
                if host.frame != placement.frame { host.frame = placement.frame }
                continue
            }
            hosts[placement.id]?.removeFromSuperview()
            let host = NSHostingView(rootView: UserLinkCardHost(key: placement.key, model: model))
            // The canvas places it; the card must not resize itself or ask
            // the canvas for room it was not given.
            host.sizingOptions = []
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
    /// reserve its space on the layout that first draws it.
    static func measure(_ key: UserCardKey, model: AppModel) -> CGSize {
        NSHostingView(rootView: UserLinkCardHost(key: key, model: model, isMeasuring: true)).fittingSize
    }
}

/// The root of one hosted card: the card, with the environment every window
/// root gives its views.
struct UserLinkCardHost: View {
    var key: UserCardKey
    var model: AppModel
    /// A card laid out only to learn its size. See `MiniProfileCard.showsEffect`.
    var isMeasuring = false

    var body: some View {
        UserLinkCard(key: key, isMeasuring: isMeasuring)
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
                openFullProfile: { model.openProfile(key.userID, anchor: .zero, depth: .full) },
                width: Self.width,
                form: .embed,
                showsEffect: !isMeasuring
            )
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                // A measuring card reports through its caller, once.
                guard !isMeasuring else { return }
                model.noteUserCardSize(size, for: key)
            }
        }
    }
}
