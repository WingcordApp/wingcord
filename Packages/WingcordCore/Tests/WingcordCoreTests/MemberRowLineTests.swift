import Foundation
import Testing
@testable import WingcordCore

/// The line under a name in the member list, by Discord's `tT` (`763349`).
@Suite("Member row line")
struct MemberRowLineTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func game(_ name: String = "Escape from Tarkov", start: Date? = nil) -> Activity {
        Activity(kind: .playing, name: name, startedAt: start)
    }

    /// Alex's screenshot 43.
    @Test("A game is its glyph, its name and how long, all green")
    func gameLine() throws {
        let line = try #require(MemberRowLine.resolve(activities: [game(start: start)]))
        #expect(line.glyph == .game)
        #expect(line.text == "Escape from Tarkov")
        #expect(line.since == start)
        #expect(line.joiner == " · ")
        #expect(line.isLive)
    }

    @Test("A game wins over a custom status, which then says nothing")
    func gameBeatsStatus() throws {
        let line = try #require(MemberRowLine.resolve(activities: [
            Activity(kind: .custom, name: "Custom Status", state: "brb", emoji: EmojiRef(name: "☕️")),
            game(),
        ]))
        #expect(line.text == "Escape from Tarkov")
        #expect(line.emoji == nil)
    }

    @Test("Listening names the artists, green glyph and muted words")
    func listening() throws {
        let line = try #require(MemberRowLine.resolve(activities: [
            Activity(
                kind: .listening, name: "Spotify", state: "Devon Hendryx", details: "God & Earrings",
                startedAt: start, partyID: "spotify:1"
            ),
        ]))
        #expect(line.glyph == .music)
        #expect(line.text == "Devon Hendryx")
        #expect(line.since == start)
        #expect(!line.isLive)
    }

    @Test("A custom status is its emoji and its words, muted")
    func customStatus() throws {
        let line = try #require(MemberRowLine.resolve(activities: [
            Activity(kind: .custom, name: "Custom Status", state: " serpent is lord ", emoji: EmojiRef(name: "🐍")),
        ]))
        #expect(line.glyph == nil)
        #expect(line.emoji?.name == "🐍")
        #expect(line.text == "serpent is lord")
        #expect(!line.isLive)
    }

    @Test("In a room, the line is the room's, green")
    func inVoice() throws {
        let line = try #require(MemberRowLine.resolve(activities: [], voice: .voiceChannel))
        #expect(line.glyph == .voice)
        #expect(line.text == "In voice")
        #expect(line.since == nil)
        #expect(line.isLive)
    }

    @Test("In a room and playing, the game only gives it a clock")
    func inVoiceAndPlaying() throws {
        let line = try #require(MemberRowLine.resolve(activities: [game(start: start)], voice: .voiceChannel))
        #expect(line.glyph == .voice)
        #expect(line.text == "Playing for")
        #expect(line.since == start)
        #expect(line.joiner == " ")
        #expect(line.isLive)
    }

    @Test("In a room with a game that has no clock is just in voice")
    func inVoiceWithAClocklessGame() throws {
        let line = try #require(MemberRowLine.resolve(activities: [game()], voice: .voiceChannel))
        #expect(line.text == "In voice")
    }

    @Test("A stage has its own glyph")
    func stage() throws {
        let line = try #require(MemberRowLine.resolve(activities: [], voice: .stage))
        #expect(line.glyph == .stage)
    }

    @Test("Sharing a screen says so, or names the game shared")
    func sharing() throws {
        #expect(MemberRowLine.resolve(activities: [], voice: .voiceChannel, isStreaming: true)?.text == "Sharing their screen")
        let line = try #require(MemberRowLine.resolve(activities: [game()], voice: .voiceChannel, isStreaming: true))
        #expect(line.glyph == .screen)
        #expect(line.text == "Escape from Tarkov")
    }

    /// **"Playing /help" is a slogan.** An app with a game activity is not
    /// somebody playing, and must not read as live.
    @Test("An app's activity has no glyph, no clock and no green")
    func botLine() throws {
        let line = try #require(MemberRowLine.resolve(activities: [game("/help", start: start)], isBot: true))
        #expect(line.glyph == nil)
        #expect(line.since == nil)
        #expect(!line.isLive)
        #expect(line.text == "/help")
    }

    @Test("Under the game's own heading, the line says what they're doing in it")
    func inGameSection() throws {
        let activity = Activity(kind: .playing, name: "Escape from Tarkov", state: "Raid", details: "Customs")
        let line = try #require(MemberRowLine.resolve(activities: [activity], inGameSection: true))
        #expect(line.text == "Customs")
        // Nothing to add: no line rather than the name twice.
        #expect(MemberRowLine.resolve(activities: [game()], inGameSection: true) == nil)
    }

    @Test("Under the room's own heading, the clock is when they joined")
    func inVoiceGroup() throws {
        let line = try #require(MemberRowLine.resolve(
            activities: [], voice: .voiceChannel, isInVoiceGroup: true, connectedAt: start
        ))
        #expect(line.text == nil)
        #expect(line.since == start)
        #expect(line.isLive)
        // Their activity outranks it, as `d` is only the fallback.
        #expect(MemberRowLine.resolve(
            activities: [game()], voice: .voiceChannel, isInVoiceGroup: true, connectedAt: start
        )?.text == "Escape from Tarkov")
    }

    @Test("Nothing going on is no line")
    func nothing() {
        #expect(MemberRowLine.resolve(activities: []) == nil)
        #expect(MemberRowLine.resolve(activities: [Activity(kind: .custom, name: "Custom Status")]) == nil)
    }

    @Test("The time, in Discord's short words", arguments: [
        (10, "1m"), (59, "1m"), (60, "1m"), (119, "1m"), (120, "2m"), (3_599, "59m"), (3_600, "1h"),
        (86_399, "23h"), (86_400, "1d"), (2_591_999, "29d"), (2_592_000, "1 mo"), (31_103_999, "11 mo"),
        (31_104_000, "1y"), (-5, "1m"),
    ])
    func duration(seconds: Int, expected: String) {
        let now = start.addingTimeInterval(TimeInterval(seconds))
        #expect(MemberRowLine.duration(since: start, now: now) == expected)
    }
}

@Suite("Member list organization")
struct MemberListOrganizationTests {
    @Test("A list that can't do a mode falls back to one that can")
    func fallbacks() {
        #expect(MemberListOrganization.roles.resolved(hasRoles: false, isWhole: true) == .activeNow)
        #expect(MemberListOrganization.roles.resolved(hasRoles: true, isWhole: false) == .roles)
        #expect(MemberListOrganization.alphabetical.resolved(hasRoles: true, isWhole: false) == .activeNow)
        #expect(MemberListOrganization.alphabetical.resolved(hasRoles: false, isWhole: true) == .alphabetical)
        #expect(MemberListOrganization.game.resolved(hasRoles: false, isWhole: false) == .game)
    }

    @Test("Names sort as Discord's collator does: no case, no accents, numbers by value")
    func sortKeys() {
        let names = ["user10", "User2", "Ähri", "ahri2", "bo", "Ada", "user1"]
        let sorted = names.sorted { MemberListOrder.sortKey($0) < MemberListOrder.sortKey($1) }
        #expect(sorted == ["Ada", "Ähri", "ahri2", "bo", "user1", "User2", "user10"])
    }

    @Test("A name files under its first letter, without its accent", arguments: [
        ("ada", "A"), ("Ähri", "A"), ("  bo", "B"), ("Åsa", "A"), ("9threvolver", "#"), ("🐍 snake", "#"),
        ("", "#"), ("ñu", "N"), ("Élan", "E"),
    ])
    func letters(name: String, expected: String) {
        #expect(MemberListOrder.letter(of: name) == expected)
    }

    @Test("Letters in order, the rest last")
    func letterOrder() {
        #expect(MemberListOrder.lettersInOrder(["#", "b", "A", "C"]) == ["A", "b", "C", "#"])
    }

    @Test("A collapsed section is written down by what it is")
    func storageKeys() {
        #expect(MemberSectionKey.role(RoleID(rawValue: 7)).storageKey == "role:7")
        #expect(MemberSectionKey.game("123").storageKey == "game:123")
        #expect(MemberSectionKey.activeNow.storageKey == "active_now")
    }
}

@Suite("Member list pages")
struct MemberListWholePagesTests {
    @Test("A list that fits is subscribed whole, whatever is on screen")
    func wholeList() {
        #expect(MemberList.pages(visible: [0...10], margin: 8, rowCount: 1) == [0...99])
        #expect(MemberList.pages(visible: [0...10], margin: 8, rowCount: 100) == [0...99])
        #expect(MemberList.pages(visible: [0...10], margin: 8, rowCount: 101) == [0...99, 100...199])
        #expect(MemberList.pages(visible: [], margin: 8, rowCount: 300) == [0...99, 100...199, 200...299])
    }

    @Test("A longer one is the first page and what's around the viewport")
    func longList() {
        #expect(MemberList.pages(visible: [510...520], margin: 8, rowCount: 5000) == [0...99, 500...599])
        #expect(MemberList.pages(visible: [495...510], margin: 8, rowCount: 5000) == [0...99, 400...499, 500...599])
    }

    /// **The hole a collapsed section leaves**: one range across it would ask for
    /// fifty pages.
    @Test("Rows either side of a collapsed section don't ask for what's between")
    func runsAcrossAHole() {
        #expect(MemberList.pages(visible: [90...99, 5000...5010], margin: 0, rowCount: 8000) == [0...99, 5000...5099])
    }

    @Test("Never more than three, nearest the viewport's start first")
    func capped() {
        let pages = MemberList.pages(visible: [150...160, 2500...2510, 5000...5010], margin: 0, rowCount: 8000)
        #expect(pages == [0...99, 100...199, 2500...2599])
        #expect(pages.count == MemberList.maximumPages)
    }
}

/// Discord's `237309` and `420825`.
@Suite("Friend request notes")
struct FriendRequestNoteTests {
    @Test("A note goes out on one line, trimmed, or not at all")
    func cleaned() {
        #expect(FriendRequestNote.cleaned("  hey\nthere\r\nfriend  ") == "hey there friend")
        #expect(FriendRequestNote.cleaned("   \n ") == nil)
        #expect(FriendRequestNote.cleaned("") == nil)
    }

    @Test("Past the limit, nothing")
    func limit() {
        #expect(FriendRequestNote.maximumLength == 120)
        #expect(FriendRequestNote.cleaned(String(repeating: "a", count: 120)) != nil)
        #expect(FriendRequestNote.cleaned(String(repeating: "a", count: 121)) == nil)
    }

    /// **What the account said wins; only an unset one falls back**, and then only
    /// `false` counts: Discord's `!1 === nsfwAllowed`.
    @Test("Showing them: the setting, else hidden only for an account not cleared")
    func shows() {
        var unset = MessagingPrivacy()
        #expect(unset.resolvedShowsFriendRequestNotes(isNSFWAllowed: nil))
        #expect(unset.resolvedShowsFriendRequestNotes(isNSFWAllowed: true))
        #expect(!unset.resolvedShowsFriendRequestNotes(isNSFWAllowed: false))

        unset.hasFriendRequestNotesSetting = true
        unset.showsFriendRequestNotes = true
        #expect(unset.resolvedShowsFriendRequestNotes(isNSFWAllowed: false))
        unset.showsFriendRequestNotes = false
        #expect(!unset.resolvedShowsFriendRequestNotes(isNSFWAllowed: true))
    }

    @Test("A note alone makes a relationship worth a row")
    func noteworthy() {
        #expect(RelationshipFacts(note: "hey").isNoteworthy)
        #expect(!RelationshipFacts().isNoteworthy)
    }
}
