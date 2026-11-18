import Foundation
import Testing
@testable import WingcordCore

/// The Server Hub's rules, as Discord's own client applies them (docs/BETA2.md,
/// phase 9).
struct GuildSpaceLayoutTests {

    private func widget(_ id: String, column: Int, order: Int) -> GuildSpaceWidget {
        GuildSpaceWidget(id: id, kind: .imageText, position: .init(column: column, order: order))
    }

    @Test("Column 1 is the side column; anything else is the main one, each in order")
    func columns() {
        let columns = GuildSpaceLayout.columns([
            widget("c", column: 1, order: 1),
            widget("a", column: 0, order: 2),
            widget("b", column: 1, order: 0),
            widget("d", column: 7, order: 0),
        ])
        #expect(columns[0].map(\.id) == ["d", "a"])
        #expect(columns[1].map(\.id) == ["b", "c"])
    }

    @Test("Normalising writes plain column and index back, with no gaps")
    func normalized() {
        let widgets = GuildSpaceLayout.normalized([
            widget("a", column: 0, order: 5),
            widget("b", column: 1, order: 9),
            widget("c", column: 0, order: 7),
        ])
        #expect(widgets.map(\.id) == ["a", "c", "b"])
        #expect(widgets.map(\.position) == [.init(column: 0, order: 0), .init(column: 0, order: 1), .init(column: 1, order: 0)])
    }

    @Test("Moving across columns lands at the index, clamped to the column")
    func moving() throws {
        let start = [widget("a", column: 0, order: 0), widget("b", column: 0, order: 1), widget("c", column: 1, order: 0)]
        let moved = try #require(GuildSpaceLayout.moving("b", in: start, toColumn: 1, index: 0))
        #expect(GuildSpaceLayout.columns(moved)[0].map(\.id) == ["a"])
        #expect(GuildSpaceLayout.columns(moved)[1].map(\.id) == ["b", "c"])
        let clamped = try #require(GuildSpaceLayout.moving("a", in: start, toColumn: 1, index: 99))
        #expect(GuildSpaceLayout.columns(clamped)[1].map(\.id) == ["c", "a"])
        #expect(GuildSpaceLayout.moving("zz", in: start, toColumn: 0, index: 0) == nil)
    }

    @Test("Removing closes the gap it leaves")
    func removing() {
        let left = GuildSpaceLayout.removing("a", from: [widget("a", column: 0, order: 0), widget("b", column: 0, order: 1)])
        #expect(left.map(\.id) == ["b"])
        #expect(left.first?.position == .init(column: 0, order: 0))
    }

    @Test("Add Widget stops offering a kind at its limit")
    func addable() {
        let catalog = [
            GuildSpaceCatalogEntry(kind: .leaderboard, name: "Gaming Leaderboard"),
            GuildSpaceCatalogEntry(kind: .imageText, name: "Image + Text", maxInstances: 2),
        ]
        let hub = [
            GuildSpaceWidget(id: "1", kind: .leaderboard, position: .init(column: 0, order: 0)),
            GuildSpaceWidget(id: "2", kind: .imageText, position: .init(column: 0, order: 1)),
        ]
        #expect(GuildSpaceCatalogEntry.addable(catalog, given: hub).map(\.kind) == [.imageText])
    }
}

struct GuildSpaceSettingsTests {

    @Test("Discord's visibility rule: off for all, a draft for editors, published for everyone")
    func visibility() {
        let off = GuildSpaceSettings(isEnabled: false, publishStatus: .published)
        #expect(!off.isVisible(toEditor: true))
        let draft = GuildSpaceSettings(isEnabled: true, publishStatus: .draft)
        #expect(draft.isVisible(toEditor: true))
        #expect(!draft.isVisible(toEditor: false))
        let published = GuildSpaceSettings(isEnabled: true, publishStatus: .published)
        #expect(published.isVisible(toEditor: false))
        // No answer about the switch: an editor still gets the page.
        let unknown = GuildSpaceSettings(isEnabled: nil, publishStatus: .published)
        #expect(unknown.isVisible(toEditor: true))
        #expect(!unknown.isVisible(toEditor: false))
    }

    @Test("Image + Text needs words or a picture")
    func imageTextContent() {
        var config = GuildSpaceWidgetConfig(kind: .imageText, title: "Only a title")
        #expect(!config.hasContent)
        config.text = "  \n "
        #expect(!config.hasContent)
        config.imageChange = .replaced(dataURL: "data:image/png;base64,AA==")
        #expect(config.hasContent)
        config.imageChange = .removed
        config.imageHash = "abc"
        #expect(!config.hasContent)
        config.imageChange = .unchanged
        #expect(config.hasContent)
    }
}

struct GuildSpaceLeaderboardTests {

    private func board(entries count: Int, weekStart: Date) -> GuildSpaceLeaderboard {
        GuildSpaceLeaderboard(
            stat: .hoursPlayed,
            nextStat: .daysPlayed,
            weekStart: weekStart,
            entries: (0..<count).map { GuildSpaceLeaderboard.Entry(userID: UserID(rawValue: UInt64($0 + 1)), rank: $0 + 1, value: 1) }
        )
    }

    @Test("Days left round up, as the badge does, and end at the week's end")
    func daysLeft() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(board(entries: 3, weekStart: now.addingTimeInterval(-6.5 * 86_400)).daysLeft(now: now) == 1)
        #expect(board(entries: 3, weekStart: now.addingTimeInterval(-2 * 86_400)).daysLeft(now: now) == 5)
        #expect(board(entries: 3, weekStart: now.addingTimeInterval(-8 * 86_400)).daysLeft(now: now) == nil)
    }

    @Test("Three people before there's a board")
    func enoughEntries() {
        #expect(!board(entries: 2, weekStart: .now).hasEnoughEntries)
        #expect(board(entries: 3, weekStart: .now).hasEnoughEntries)
    }

    @Test("The top twenty, then the reader wherever they rank")
    func visibleEntries() {
        let full = board(entries: 30, weekStart: .now)
        let rows = full.visibleEntries(limit: 20, reader: UserID(rawValue: 27))
        #expect(rows.count == 21)
        #expect(rows.last?.rank == 27)
        #expect(full.visibleEntries(limit: 20, reader: UserID(rawValue: 3)).count == 20)
    }

    @Test("The podium rises on the week's seventh Pacific day")
    func finalDay() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: "2027-01-09")!
        var board = board(entries: 3, weekStart: start)
        board.dayPT = "2027-01-15"
        #expect(board.isFinalDay)
        board.dayPT = "2027-01-12"
        #expect(!board.isFinalDay)
    }

    /// Discord reads `day_pt` with `new Date()`, and its own fixtures write a
    /// full timestamp — which this used to refuse, leaving the podium down.
    @Test("The podium rises on a day_pt written as a full timestamp", arguments: [
        "2027-01-15T00:00:00.000Z",
        "2027-01-15T00:00:00Z",
        "2027-01-15T08:00:00+00:00",
    ])
    func finalDayFromTimestamp(dayPT: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var board = board(entries: 3, weekStart: formatter.date(from: "2027-01-09")!)
        board.dayPT = dayPT
        #expect(board.isFinalDay)
    }

    @Test("A day_pt that isn't a date never raises the podium")
    func finalDayRejectsNonsense() {
        var board = board(entries: 3, weekStart: Date(timeIntervalSince1970: 1_800_000_000))
        board.dayPT = "sometime"
        #expect(!board.isFinalDay)
    }
}

struct GuildSpaceFormatTests {

    @Test("Game time is hours and minutes, as Discord writes it")
    func playTime() {
        #expect(GuildSpaceFormat.playTime(seconds: 44 * 3_600 + 45 * 60) == "44h 45m")
        #expect(GuildSpaceFormat.playTime(seconds: 12 * 3_600) == "12h")
        #expect(GuildSpaceFormat.playTime(seconds: 35 * 60 + 20) == "35m")
    }

    @Test("A value reads in its stat's unit — milliseconds for game time")
    func values() {
        #expect(GuildSpaceFormat.value(3_600_000 * 3.5, stat: .hoursPlayed) == "3h 30m")
        #expect(GuildSpaceFormat.value(1, stat: .daysPlayed) == "1 day")
        #expect(GuildSpaceFormat.value(12, stat: .uniqueGamesPlayed) == "12 games")
        #expect(GuildSpaceFormat.achievement(5, stat: .daysPlayed) == "5 game days")
    }
}

struct GuildSpaceSystemTextTests {

    private func message(_ data: GuildSpaceMessageData) -> Message {
        Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            authorID: UserID(rawValue: 3),
            content: "",
            kind: .guildSpace,
            payload: MessagePayload(guildSpaceData: data)
        )
    }

    @Test("A new leader is named, with the one overtaken and the time")
    func leaderChanged() throws {
        let data = GuildSpaceMessageData(leaderboard: .init(
            event: .leaderChanged, stat: .hoursPlayed,
            userID: UserID(rawValue: 10), secondaryUserID: UserID(rawValue: 11), value: 3_600_000 * 44.75
        ))
        let sentence = try #require(SystemMessageText.sentence(
            for: message(data), name: "Blåhaj", nameOf: { $0.rawValue == 11 ? "bram" : nil }
        ))
        #expect(sentence.name == "Blåhaj")
        // The one overtaken is a bold run of its own, as Discord sets them.
        #expect(sentence.suffix == " took 1st Place from ")
        #expect(sentence.emphasis == "bram")
        #expect(sentence.tail == " on the leaderboard with 44h 45m of game time.")
        #expect(data.subjectUserID == UserID(rawValue: 10))
    }

    @Test("A new competition asks its question and names who leads")
    func started() throws {
        let data = GuildSpaceMessageData(leaderboard: .init(
            event: .started, stat: .daysPlayed, userID: UserID(rawValue: 10), secondaryUserID: nil, value: 2
        ))
        let sentence = try #require(SystemMessageText.sentence(for: message(data), name: "pip"))
        #expect(sentence.prefix.hasSuffix("with the most game days? So far "))
        #expect(sentence.suffix == " is in the lead.")
    }

    @Test("A busy whiteboard says who is drawing, or just that it's busy")
    func whiteboard() throws {
        let quiet = try #require(SystemMessageText.sentence(
            for: message(.init(whiteboard: .init(sampledUserIDs: [], connectedUserCount: 0))), name: ""
        ))
        #expect(quiet.prefix == "The whiteboard is active.")
        let busy = try #require(SystemMessageText.sentence(
            for: message(.init(whiteboard: .init(sampledUserIDs: [UserID(rawValue: 4)], connectedUserCount: 3))), name: "rin"
        ))
        #expect(busy.suffix == " and 2 others are drawing on the whiteboard.")
    }

    @Test("The music's new tops")
    func music() throws {
        let song = try #require(SystemMessageText.sentence(
            for: message(.init(music: .init(event: .topSong, trackTitle: "Nights", artistName: "Frank Ocean", userID: nil))), name: ""
        ))
        #expect(song.emphasis == "Nights is the new top song!")
        let listener = try #require(SystemMessageText.sentence(
            for: message(.init(music: .init(event: .topListener, trackTitle: nil, artistName: nil, userID: UserID(rawValue: 5)))), name: "vale"
        ))
        #expect(listener.suffix == " is the new top listener!")
    }
}
