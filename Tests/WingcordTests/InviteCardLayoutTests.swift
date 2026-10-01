import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Discord's invite embed, laid out: which card a link gets, when a server's
/// folds, and what its button says.
@MainActor
struct InviteCardLayoutTests {

    private let style = MessageTextStyle.current()
    private let guildID = GuildID(rawValue: 1_520_000_000_000_000_001)

    private func server(description: String? = nil, traits: [GuildTrait] = [], features: Set<String> = ["COMMUNITY"])
        -> InviteCard {
        InviteCard(
            code: "LumenClub", kind: .server, guildID: guildID, name: "Lumen Club",
            features: features, memberCount: 121, onlineCount: 38,
            profile: GuildProfile(
                id: guildID, name: "Lumen Club", description: description,
                memberCount: 121, onlineCount: 38, traits: traits, features: features
            ),
            inviterID: UserID(rawValue: 5), inviterName: "alex"
        )
    }

    private func layout(_ card: InviteCard?, expanded: Bool = false, selfIDs: Set<UInt64> = []) -> InviteCardSlot {
        InviteCardLayoutEngine.layout(
            code: card?.code ?? "gone",
            lookup: card.map(InviteLookup.resolved) ?? .invalid,
            sentByReader: false,
            selfIDs: selfIDs,
            isExpanded: expanded,
            palettes: [:],
            origin: .zero,
            availableWidth: 600,
            style: style
        )
    }

    @Test("A server with a profile gets Discord's profile card, 300 wide, with its mark")
    func profileCard() {
        let slot = layout(server())
        guard case .profile = slot.body else {
            Issue.record("expected the profile card")
            return
        }
        #expect(slot.rect.width == 300)
        #expect(slot.mark?.kind == .community)
        #expect(slot.markRect != .zero)
        guard case .none = slot.fold else {
            Issue.record("a short card does not fold")
            return
        }
    }

    /// Discord's 292: past it the card is cut, and opened it gains Hide Details
    /// above the button.
    @Test("A tall profile card folds at 292 and opens past it")
    func fold() {
        let long = String(repeating: "A server about a great many things. ", count: 14)
        let folded = layout(server(description: long))
        #expect(folded.rect.height == InviteCardLayoutEngine.foldHeight)
        guard case .collapsed = folded.fold else {
            Issue.record("expected the card to fold")
            return
        }
        #expect(folded.foldTarget == folded.rect)

        let open = layout(server(description: long), expanded: true)
        #expect(open.rect.height > InviteCardLayoutEngine.foldHeight)
        guard case .expanded(let hide, _, _) = open.fold, let button = open.button else {
            Issue.record("expected Hide Details and a button")
            return
        }
        #expect(hide.maxY <= button.rect.minY)
        #expect(open.foldTarget == hide)
    }

    @Test("Apply to Join for a server that reviews applications")
    func applyToJoin() {
        let card = server(features: [
            "COMMUNITY", "MEMBER_VERIFICATION_GATE_ENABLED", "MEMBER_VERIFICATION_MANUAL_APPROVAL",
        ])
        #expect(layout(card).button?.pending.label.text.attributed.string == "Apply to Join")
        #expect(layout(card).button?.settled.label.text.attributed.string == "Go to Server")
    }

    /// Your own friend link: Discord draws Add Friend, grey and disabled.
    @Test("Your own friend link is drawn and not pressable")
    func ownFriendLink() {
        let card = InviteCard(
            code: "f", kind: .friend, name: "alex",
            inviterID: UserID(rawValue: 9), inviterName: "alex", inviterUsername: "alexsample"
        )
        let mine = layout(card, selfIDs: [9])
        #expect(mine.button?.isEnabled == false)
        #expect(mine.button?.pending.isProminent == false)
        let theirs = layout(card, selfIDs: [1])
        #expect(theirs.button?.isEnabled == true)
        #expect(theirs.button?.pending.isProminent == true)
        #expect(theirs.button?.settled.label.text.attributed.string == "Send a Message")
    }

    @Test("An invite that is gone has no button")
    func invalid() {
        let slot = layout(nil)
        #expect(slot.button == nil)
        guard case .classic(let classic) = slot.body else {
            Issue.record("expected the classic card")
            return
        }
        #expect(classic.title.text.attributed.string == "Invalid Invite")
        // Discord's red tile in place of an icon, and nothing to fetch for it.
        #expect(classic.isExpired)
        #expect(classic.iconURL == nil)
    }

    @Test("A monogram is centred in its tile, not set against its leading edge")
    func monogramCentred() {
        let card = InviteCard(code: "abc", kind: .server, name: "Wingcord")
        guard case .classic(let classic) = layout(card).body,
              let paragraph = classic.monogram.text.attributed.attribute(
                  .paragraphStyle, at: 0, effectiveRange: nil
              ) as? NSParagraphStyle
        else {
            Issue.record("expected a classic card with a styled monogram")
            return
        }
        #expect(paragraph.alignment == .center)
        #expect(classic.monogram.size.width == classic.iconRect.width)
        #expect(!classic.isExpired)
    }
}
