import Foundation
import Testing
@testable import WingcordCore

/// Emoji tokens, connection links and the friend slot.
@Suite("What a person's row offers")
struct UserActionTests {

    // MARK: Emoji tokens

    @Test("A custom emoji round-trips through its inline form")
    func customEmojiRoundTrip() {
        let still = EmojiRef(id: EmojiID(rawValue: 12_597), name: "blobcat", isAnimated: false)
        #expect(EmojiRef(messageToken: still.messageToken) == still)

        let moving = EmojiRef(id: EmojiID(rawValue: 42), name: "party", isAnimated: true)
        #expect(moving.messageToken == "<a:party:42>")
        #expect(EmojiRef(messageToken: moving.messageToken) == moving)
    }

    @Test("A Unicode emoji is its own token")
    func unicodeRoundTrip() {
        let thumb = EmojiRef(name: "👍")
        #expect(EmojiRef(messageToken: thumb.messageToken) == thumb)
    }

    @Test("Anything that is not a token is refused rather than half-parsed")
    func malformedTokensAreRefused() {
        #expect(EmojiRef(messageToken: "") == nil)
        #expect(EmojiRef(messageToken: "<:name>") == nil)
        #expect(EmojiRef(messageToken: "<:name:notanumber>") == nil)
        #expect(EmojiRef(messageToken: "<::123>") == nil)
    }

    // MARK: Connections

    @Test("A service with a public page gets an address built from the right field")
    func connectionLinks() {
        // Steam addresses by id; the visible name is not addressable at all.
        let steam = ConnectedAccount(
            id: "76561198000000000", service: "steam", name: "Mifmaff", isVerified: true
        )
        #expect(
            steam.profileURL?.absoluteString
                == "https://steamcommunity.com/profiles/76561198000000000"
        )

        let github = ConnectedAccount(
            id: "999", service: "github", name: "octocat", isVerified: true
        )
        #expect(github.profileURL?.absoluteString == "https://github.com/octocat")
    }

    @Test("A service with no public page has no address, and that is the answer")
    func connectionsWithoutLinks() {
        for service in ["playstation", "xbox", "battlenet", "riotgames", "epicgames"] {
            let account = ConnectedAccount(
                id: "1", service: service, name: "somebody", isVerified: true
            )
            #expect(account.profileURL == nil, "\(service) should have no page")
        }
    }

    @Test("A name with a slash in it cannot escape the host it was built for")
    func connectionNamesArePercentEncoded() {
        let hostile = ConnectedAccount(
            id: "1", service: "twitch", name: "a b", isVerified: false
        )
        #expect(hostile.profileURL?.host() == "www.twitch.tv")
        #expect(hostile.profileURL?.absoluteString == "https://www.twitch.tv/a%20b")
    }

    @Test("An empty name yields no address rather than the bare host")
    func emptyConnectionNames() {
        let blank = ConnectedAccount(id: "", service: "github", name: "", isVerified: false)
        #expect(blank.profileURL == nil)
    }

    // MARK: The friend slot

    @Test("Each relationship names one act, and blocked names none")
    func friendRowWords() {
        #expect(Relationship.none.friendActionTitle == "Add Friend")
        #expect(Relationship.friend.friendActionTitle == "Remove Friend")
        #expect(Relationship.incomingRequest.friendActionTitle == "Accept Friend Request")
        #expect(Relationship.outgoingRequest.friendActionTitle == "Cancel Friend Request")
        // Blocking is its own control; one act reachable by two names is how a
        // "remove friend" silently unblocks somebody.
        #expect(Relationship.blocked.friendActionTitle == nil)
    }

    @Test("Sending and accepting are the same PUT; the other two are the DELETE")
    func friendDirection() {
        #expect(Relationship.none.friendActionAdds)
        #expect(Relationship.incomingRequest.friendActionAdds)
        #expect(!Relationship.friend.friendActionAdds)
        #expect(!Relationship.outgoingRequest.friendActionAdds)
    }

    @Test("An unknown relationship type reads as none rather than as a friend")
    func unknownRelationshipsFailSafe() {
        #expect(Relationship(rawValue: 99) == .none)
        #expect(Relationship(rawValue: 5) == .none)
    }

    @Test("Only dropping a friend is tinted destructive")
    func destructiveTint() {
        #expect(Relationship.friend.friendActionIsDestructive)
        #expect(!Relationship.outgoingRequest.friendActionIsDestructive)
        #expect(!Relationship.none.friendActionIsDestructive)
    }
}
