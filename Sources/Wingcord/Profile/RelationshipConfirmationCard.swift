import SwiftUI
import WingcordCore

/// Which of the two is being asked about.
struct RelationshipConfirmation: Identifiable, Hashable, Sendable {
    enum Mode: Hashable, Sendable {
        case ignore
        case block
    }

    var userID: UserID
    var mode: Mode

    var id: UserID { userID }
}

/// Discord's "Ignore {name}?" and "Block {name}?" — in the shape Alex sent
/// (docs/references/2026-10-26/15): the person's face wearing what is about to
/// happen to them, what it does in a few checked lines, the other choice as a
/// link, and two capsules.
///
/// **One card that turns in place** (D11c): "Block instead" does not close
/// this and open another — the badge, the title, the lines and the act change
/// where they are, and the card resizes around them. Every word is Discord's
/// (stable 649389, the safety strings beside `WrQD/Y` and `CIbzHR`).
struct RelationshipConfirmationCard: View {
    var request: RelationshipConfirmation

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var mode: RelationshipConfirmation.Mode

    init(request: RelationshipConfirmation) {
        self.request = request
        _mode = State(initialValue: request.mode)
    }

    var body: some View {
        let user = model.users[request.userID]
        let name = user?.preferredName ?? "them"
        ModalAlert(
            hero: .avatar(
                user.flatMap { model.avatarURL(for: $0, side: ModalHero.side) },
                monogram: user?.monogram ?? "",
                badge: mode == .ignore ? "eye.slash" : "hand.raised.fill"
            ),
            title: mode == .ignore ? "Ignore \(name)?" : "Block \(name)?",
            points: points(isFriend: model.relationships[request.userID] == .friend),
            link: ModalLink(title: mode == .ignore ? "Block instead" : "Ignore instead") {
                withAnimation(motion.reposition) {
                    mode = mode == .ignore ? .block : .ignore
                }
                Haptics.tick()
            },
            actions: [
                .cancel(),
                mode == .ignore
                    ? .act("Ignore", symbol: "eye.slash") { model.setIgnored(true, userID: request.userID) }
                    : .act("Block", symbol: "hand.raised.fill") { model.setBlocked(true, userID: request.userID) },
            ]
        )
        // **The same card, its contents changing where they are**: the lines
        // fade through, the badge swaps its symbol, and the ground resizes
        // with them — no second card.
        .animation(motion.reposition, value: mode)
    }

    private func points(isFriend: Bool) -> [ModalPoint] {
        switch mode {
        case .ignore:
            return [
                .check("Hide their profile and messages", detail: "You can unhide them at any time"),
                .check("Mute their notifications and activity", detail: "You\u{2019}ll see less of them on Discord"),
                .note("They can still message you and see your activity", detail: "They won\u{2019}t know you\u{2019}ve ignored them"),
            ]
        case .block:
            var lines: [ModalPoint] = [
                .check("Stop direct messages", detail: "You can unhide past messages if you want"),
                .check("Limit access to your profile and activity", detail: "They won\u{2019}t see your mutual friends, bio or status"),
            ]
            if isFriend { lines.append(.check("They will be unfriended")) }
            lines.append(.note(
                "They can interact with you in GDMs and servers",
                detail: "If you join a voice channel that they\u{2019}re active in, we\u{2019}ll let you know"
            ))
            return lines
        }
    }
}
