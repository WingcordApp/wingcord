import Testing
import WingcordCore
@testable import Wingcord

/// What the `/` list is derived from, and what it offers once a command is
/// chosen.
///
/// Every case here is one ordinary typing hits, and the ones that matter are
/// the **negatives** — a command list that opens on a URL or on a message that
/// merely begins with a slash is a list covering the transcript while somebody
/// is trying to write.
@Suite("Slash commands")
struct SlashCommandTests {

    // MARK: Reading the draft

    @Test("A command opens on the first character and nowhere else")
    func opensAtTheHead() {
        #expect(CommandQuery.query(in: "/") == "")
        #expect(CommandQuery.query(in: "/8ball") == "8ball")
        // The whole remainder, spaces included — a leaf is named `base64 decode`
        // and a query that stopped at the first space could never reach it.
        #expect(CommandQuery.query(in: "/base64 dec") == "base64 dec")
    }

    @Test("A slash anywhere else is not a command")
    func ignoresSlashesInsideText() {
        #expect(CommandQuery.query(in: "and/or") == nil)
        #expect(CommandQuery.query(in: "see https://example.com") == nil)
        #expect(CommandQuery.query(in: " /8ball") == nil)
        #expect(CommandQuery.query(in: "") == nil)
    }

    /// A draft that has grown a second line is a message somebody is writing,
    /// not a command they are naming.
    @Test("A multi-line draft is a message, whatever it starts with")
    func ignoresMultiLineDrafts() {
        #expect(CommandQuery.query(in: "/not a command\nsecond line") == nil)
    }

    // MARK: Ranking

    private let esmBot = ApplicationID(rawValue: 429_305_856_241_172_480)
    private let wordleApp = ApplicationID(rawValue: 1_211_781_489_931_452_447)

    private func command(
        _ name: String,
        app: ApplicationID,
        rank: Int? = nil,
        summary: String = "",
        options: [CommandOption] = []
    ) -> SlashCommand {
        SlashCommand(
            command: ApplicationCommand(
                id: name, kind: .chatInput, applicationID: app,
                version: "1", name: name, summary: summary,
                options: options, popularityRank: rank
            ),
            parameters: options,
            summary: summary
        )
    }

    private var applications: [ApplicationID: CommandApplication] {
        [
            esmBot: CommandApplication(id: esmBot, name: "esmBot"),
            wordleApp: CommandApplication(id: wordleApp, name: "Wordle"),
        ]
    }

    /// An exact name beats a prefix beats a substring. A reader who typed the
    /// whole name means that command.
    @Test("Matches rank exact, then prefix, then substring")
    func ranksByHowWellTheNameMatches() {
        let leaves = [
            command("wordleish", app: esmBot),
            command("play-wordle", app: esmBot),
            command("wordle", app: wordleApp),
        ]
        let names = CommandSearch.matches("wordle", in: leaves, applications: applications)
            .map(\.name)
        #expect(names == ["wordle", "wordleish", "play-wordle"])
    }

    /// **The application's own name is searchable**, which is the gesture that
    /// replaces the app rail Discord draws beside its list.
    @Test("An application's name reaches its commands")
    func findsCommandsByApplication() {
        let leaves = [command("help", app: esmBot), command("wordle", app: wordleApp)]
        #expect(
            CommandSearch.matches("esm", in: leaves, applications: applications).map(\.name)
                == ["help"]
        )
    }

    @Test("A description reaches a command whose name does not")
    func findsCommandsByDescription() {
        let leaves = [command("8ball", app: esmBot, summary: "Asks the magic 8-ball a question")]
        #expect(!CommandSearch.matches("magic", in: leaves, applications: applications).isEmpty)
        #expect(CommandSearch.matches("nothing", in: leaves, applications: applications).isEmpty)
    }

    /// A command with no rank sorts last, not first: absence means "nobody has
    /// run this", not "rank zero".
    @Test("An empty query orders by popularity, unranked last")
    func ordersByPopularity() {
        let leaves = [
            command("zebra", app: esmBot),
            command("wordle", app: wordleApp, rank: 1),
            command("avatar", app: esmBot, rank: 3),
        ]
        #expect(
            CommandSearch.matches("", in: leaves, applications: applications).map(\.name)
                == ["wordle", "avatar", "zebra"]
        )
    }

    // MARK: What a row says

    /// Required options are named because they are what the reader is about to
    /// be asked for; optional ones are counted, because naming eight of them
    /// fills the row with words nobody reads.
    @Test("The hint names required options and counts the rest")
    func hintNamesRequiredCountsOptional() {
        let leaf = command(
            "meme", app: esmBot,
            options: [
                CommandOption(kind: .string, name: "text", isRequired: true),
                CommandOption(kind: .string, name: "link"),
                CommandOption(kind: .boolean, name: "togif"),
            ]
        )
        #expect(AppModel.hint(for: leaf) == "text  +2 optional")
        #expect(AppModel.hint(for: command("ping", app: esmBot)).isEmpty)
    }

    /// An attachment option is not offered and must not be counted as one that
    /// is — a row promising `+1 optional` for something the reader cannot fill
    /// is the inert control §5.5 forbids, in words instead of pixels.
    @Test("An attachment option is not counted in the hint")
    func hintIgnoresAttachments() {
        let leaf = command(
            "meme", app: esmBot,
            options: [
                CommandOption(kind: .string, name: "text", isRequired: true),
                CommandOption(kind: .attachment, name: "image"),
            ]
        )
        #expect(AppModel.hint(for: leaf) == "text")
    }

    // MARK: Which options take a list

    /// The keyboard's whole contract rests on this: **a list means Return
    /// picks, no list means Return commits.** Anything looser puts two meanings
    /// on one key.
    @Test("Closed sets are exactly the kinds a typed value cannot answer")
    func closedSetsAreTheOnesAListCanAnswer() {
        #expect(AppModel.isClosedSet(CommandOption(kind: .boolean, name: "b")))
        #expect(AppModel.isClosedSet(CommandOption(kind: .user, name: "u")))
        #expect(AppModel.isClosedSet(CommandOption(kind: .channel, name: "c")))
        #expect(AppModel.isClosedSet(CommandOption(kind: .role, name: "r")))
        #expect(AppModel.isClosedSet(CommandOption(kind: .mentionable, name: "m")))
        #expect(AppModel.isClosedSet(
            CommandOption(
                kind: .string, name: "font",
                choices: [CommandChoice(name: "impact", value: .string("impact"))]
            )
        ))

        #expect(!AppModel.isClosedSet(CommandOption(kind: .string, name: "s")))
        #expect(!AppModel.isClosedSet(CommandOption(kind: .integer, name: "i")))
        #expect(!AppModel.isClosedSet(CommandOption(kind: .number, name: "n")))
        // An option the application autocompletes still accepts anything typed:
        // the suggestions are suggestions, and the wire takes the string either
        // way.
        #expect(!AppModel.isClosedSet(
            CommandOption(kind: .string, name: "artist", autocompletes: true)
        ))
    }

    // MARK: Turning what was typed into a value

    /// `abc` in an integer option must not become a body the application
    /// refuses — Return does nothing instead.
    @Test("A typed value is refused when it will not convert")
    func refusesValuesOfTheWrongType() {
        #expect(CommandOption(kind: .integer, name: "n").value(from: "12") == .integer(12))
        #expect(CommandOption(kind: .integer, name: "n").value(from: "abc") == nil)
        #expect(CommandOption(kind: .number, name: "n").value(from: "1.5") == .number(1.5))
        #expect(CommandOption(kind: .integer, name: "n").value(from: "1.5") == nil)
    }

    /// The bounds the index declares are the application's own, and a value
    /// outside them is one it will reject.
    @Test("Declared bounds are enforced before the interaction is posted")
    func enforcesDeclaredBounds() {
        let bounded = CommandOption(kind: .integer, name: "max", minValue: 1, maxValue: 100)
        #expect(bounded.value(from: "50") == .integer(50))
        #expect(bounded.value(from: "0") == nil)
        #expect(bounded.value(from: "101") == nil)

        let short = CommandOption(kind: .string, name: "text", maxLength: 4)
        #expect(short.value(from: "abcd") == .string("abcd"))
        #expect(short.value(from: "abcde") == nil)
    }
}
