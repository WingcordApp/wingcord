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

    /// A text block is as wide as it was given (INVARIANTS §4.85), so a mark
    /// placed after an unhugged name sat at the card's far edge — Alex's image
    /// of a "Wingcord" card, 2026-10-06.
    @Test("The mark sits right after a short name, not at the card's edge")
    func markFollowsTheName() {
        let slot = layout(server())
        guard case .profile(let profile) = slot.body else {
            Issue.record("expected the profile card")
            return
        }
        #expect(slot.markRect.minX == profile.titleOrigin.x + profile.title.size.width + 4)
        #expect(slot.markRect.maxX < slot.rect.maxX - 100)
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

    /// Images 42–43 (2026-10-07): a trait chip and "Invited by" ghosted
    /// through under the button, because the fade ran to the card's fill and
    /// that fill is translucent. The content is erased now, so the strip
    /// between the fade's foot and the button is the card's ground alone —
    /// the same pixels whatever was laid out there.
    @Test("A folded card shows nothing of its content under the fade")
    func foldErasesWhatItHides() {
        // Two descriptions that read differently all the way down, so any of
        // their words left in the strip makes the two strips differ.
        let one = String(repeating: "A server about a great many things. ", count: 14)
        let two = String(repeating: "Wholly other words, set otherwise! ", count: 14)
        func strip(_ card: InviteCard) -> [UInt8] {
            let slot = layout(card)
            guard case .collapsed(let fade) = slot.fold, let button = slot.button else {
                Issue.record("expected a folded card with a button")
                return []
            }
            let pixels = RenderProbe.pixels(width: 320, height: Int(slot.rect.height) + 10) { context, _ in
                TimelineRowPainter.drawInviteCard(
                    slot, offset: .zero, context: context, isSettled: false,
                    hovered: nil, images: ImageStore.shared, scale: 1, style: style
                )
            }
            var region: [UInt8] = []
            for y in Int(fade.maxY.rounded(.up)) + 1..<Int(button.rect.minY) - 1 {
                for x in 40..<260 {
                    let index = (y * 320 + x) * 4
                    region.append(contentsOf: pixels[index..<index + 4])
                }
            }
            return region
        }
        let first = strip(server(description: one))
        let second = strip(server(description: two))
        #expect(!first.isEmpty)
        #expect(first == second)
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
    /// Discord's overflow list: two lines of chips at most, and "+ N more"
    /// (`vGclWm`) at the end of the second, carrying what it stands for.
    @Test("Traits past two lines become a \"+ N more\" chip that holds the rest")
    func moreTraits() throws {
        let traits = (0..<5).map { GuildTrait(id: $0, label: "A rather long trait number \($0)") }
        guard case .profile(let profile) = layout(server(traits: traits)).body else {
            Issue.record("expected the profile card")
            return
        }
        let more = try #require(profile.moreTraits)
        let chip = try #require(profile.traits.last)
        // The chip is the last of the drawn ones, and visible and hidden
        // together are every trait.
        #expect(more.rect == chip.rect)
        #expect(profile.traits.count - 1 + more.traits.count == traits.count)
        #expect(more.traits.map(\.id) == Array(traits.suffix(more.traits.count)).map(\.id))
        #expect(chip.label.text.attributed.string == "+ \(more.traits.count) more")
    }

    /// Alex's 2026-10-26 screenshot: four short traits came out as one "+ 4
    /// more" across the card, because every chip was as wide as the label's
    /// box (§4.85) rather than its words. A fixture of short words, the way
    /// servers actually describe themselves (§2.6).
    @Test("Short traits all show, each chip only as wide as its words")
    func shortTraitsShow() throws {
        let traits = [
            GuildTrait(id: 0, emojiName: "video_game", label: "Gaming"),
            GuildTrait(id: 1, emojiName: "pick", label: "Minecraft"),
            GuildTrait(id: 2, emojiName: "tools", label: "Modding"),
            GuildTrait(id: 3, emojiName: "speech_balloon", label: "English"),
        ]
        let slot = layout(server(description: "The home for everything AngelAuraMC.", traits: traits))
        guard case .profile(let profile) = slot.body else {
            Issue.record("expected the profile card")
            return
        }
        #expect(profile.moreTraits == nil)
        #expect(profile.traits.count == 4)
        for chip in profile.traits {
            #expect(chip.rect.width < 120, "a chip hugs its words")
            #expect(slot.rect.contains(chip.rect), "every chip is inside its card")
        }
        try expectNoOverlap(profile.traits.map(\.rect))
    }

    @Test("Many traits keep two lines and room for \"+ N more\" inside the card")
    func manyTraitsOverflowInside() throws {
        let words = ["Gaming", "Minecraft", "Modding", "English", "Art", "Music", "Anime", "Coding", "Memes", "Events"]
        let traits = words.enumerated().map { GuildTrait(id: $0.offset, emojiName: "sparkles", label: $0.element) }
        let slot = layout(server(traits: traits))
        guard case .profile(let profile) = slot.body else {
            Issue.record("expected the profile card")
            return
        }
        let more = try #require(profile.moreTraits)
        let rows = Set(profile.traits.map(\.rect.minY))
        #expect(rows.count <= 2, "two lines at most, the overflow chip included")
        #expect(profile.traits.count - 1 >= 4, "the short ones fill the lines first")
        #expect(profile.traits.count - 1 + more.traits.count == traits.count)
        for chip in profile.traits { #expect(slot.rect.contains(chip.rect)) }
        try expectNoOverlap(profile.traits.map(\.rect))
    }

    private func expectNoOverlap(_ rects: [CGRect]) throws {
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] where a.intersects(b) {
                Issue.record("chips \(a) and \(b) overlap")
            }
        }
    }

    @Test("Traits that fit leave no \"+ N more\"")
    func noMoreTraits() {
        let traits = [GuildTrait(id: 0, label: "Art"), GuildTrait(id: 1, label: "Games")]
        guard case .profile(let profile) = layout(server(traits: traits)).body else {
            Issue.record("expected the profile card")
            return
        }
        #expect(profile.moreTraits == nil)
        #expect(profile.traits.count == 2)
    }

    /// Discord's own walk (`3666`), pinned case by case.
    @Test("The overflow rule places chips as Discord's does")
    func overflowRule() {
        func lines(_ widths: [CGFloat], container: CGFloat = 210, maxLines: Int = 2, overflow: CGFloat = 60) -> [Int?] {
            TraitOverflow.layout(widths: widths, maxLines: maxLines, gap: 4,
                                 containerWidth: container, overflowWidth: overflow).lines
        }
        // Everything fits on the first line.
        #expect(lines([50, 50, 50]) == [0, 0, 0])
        // The third chip wraps; on the last line the fourth must leave room for
        // "+ N more" and cannot, so the run ends there.
        #expect(lines([100, 100, 100, 100, 100]) == [0, 0, 1, nil, nil])
        // The very last chip reserves nothing.
        #expect(lines([100, 100], maxLines: 1) == [0, 0])
        // But one before it does.
        #expect(lines([100, 100, 10], maxLines: 1) == [0, nil, nil])
        // A chip wider than the whole row is skipped, not wrapped.
        #expect(lines([300, 50], container: 200) == [nil, 0])
    }
}
