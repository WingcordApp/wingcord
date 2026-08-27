import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A message carrying a poll has **no body at all**, so everything a reader sees
/// comes out of this decode.
@Suite("Poll decoding")
struct PollDecodeTests {

    private func decode(_ json: String) throws -> Poll? {
        try JSONDecoder().decode(PollDTO.self, from: Data(json.utf8)).domain
    }

    private let closed = """
    {"question":{"text":"Should I make a nightly update program?"},
     "answers":[
       {"answer_id":1,"poll_media":{"text":"Yes, let them break!","emoji":{"name":"🔥"}}},
       {"answer_id":2,"poll_media":{"text":"Nah, keep them polished"}}],
     "allow_multiselect":false,
     "results":{"is_finalized":true,"answer_counts":[
       {"id":1,"count":10,"me_voted":true},{"id":2,"count":2,"me_voted":false}]}}
    """

    @Test("The question, the answers and the tally all survive")
    func fields() throws {
        let poll = try #require(try decode(closed))
        #expect(poll.question == "Should I make a nightly update program?")
        #expect(poll.answers.count == 2)
        #expect(poll.answers[0].emoji?.name == "🔥")
        #expect(poll.answers[0].count == 10)
        #expect(poll.answers[0].isMine)
        #expect(poll.totalVotes == 12)
        #expect(poll.isClosed)
    }

    @Test("Shares are the fraction of the whole vote")
    func shares() throws {
        let poll = try #require(try decode(closed))
        let first = Int((poll.share(of: poll.answers[0]) * 100).rounded())
        let second = Int((poll.share(of: poll.answers[1]) * 100).rounded())
        #expect(first == 83)
        #expect(second == 17)
    }

    /// **An answer missing from the tally has had no votes, not unknown votes.**
    /// Discord omits the entry rather than sending a zero, and reading absence
    /// as "not yet known" is what leaves a fresh poll with no bars at all.
    @Test("An answer absent from the counts is zero, not missing")
    func absentCountIsZero() throws {
        let poll = try #require(try decode("""
        {"question":{"text":"Pick one"},
         "answers":[{"answer_id":1,"poll_media":{"text":"A"}},
                    {"answer_id":2,"poll_media":{"text":"B"}}],
         "results":{"is_finalized":false,"answer_counts":[{"id":1,"count":3}]}}
        """))
        #expect(poll.answers.count == 2)
        #expect(poll.answers[1].count == 0)
        #expect(poll.totalVotes == 3)
    }

    /// A poll nobody has answered would divide by zero, which lays out as a
    /// crash rather than as an empty bar.
    @Test("A poll with no votes has zero shares, not NaN")
    func noVotes() throws {
        let poll = try #require(try decode("""
        {"question":{"text":"Pick one"},"answers":[{"answer_id":1,"poll_media":{"text":"A"}}]}
        """))
        #expect(poll.totalVotes == 0)
        #expect(poll.share(of: poll.answers[0]) == 0)
    }

    /// **Results are hidden until there is a reason to show them.** Before that
    /// the bars would tell everybody how to vote.
    @Test("Results appear after voting, or after closing")
    func resultsAreGated() throws {
        let open = try #require(try decode("""
        {"question":{"text":"q"},"answers":[{"answer_id":1,"poll_media":{"text":"A"}}],
         "results":{"is_finalized":false,"answer_counts":[{"id":1,"count":3}]}}
        """))
        #expect(!open.showsResults)

        let voted = try #require(try decode("""
        {"question":{"text":"q"},"answers":[{"answer_id":1,"poll_media":{"text":"A"}}],
         "results":{"is_finalized":false,"answer_counts":[{"id":1,"count":3,"me_voted":true}]}}
        """))
        #expect(voted.showsResults)

        let finished = try #require(try decode(closed))
        #expect(finished.showsResults)
    }

    /// "Winning answer" is a claim, and a tie is not one.
    @Test("A tie has no winner")
    func tieHasNoWinner() throws {
        let poll = try #require(try decode("""
        {"question":{"text":"q"},
         "answers":[{"answer_id":1,"poll_media":{"text":"A"}},
                    {"answer_id":2,"poll_media":{"text":"B"}}],
         "results":{"is_finalized":true,"answer_counts":[
           {"id":1,"count":4},{"id":2,"count":4}]}}
        """))
        #expect(poll.winner == nil)
        #expect(try #require(try decode(closed)).winner?.id == 1)
    }

    @Test("A poll with no question is not a poll")
    func questionless() throws {
        #expect(try decode(#"{"answers":[{"answer_id":1,"poll_media":{"text":"A"}}]}"#) == nil)
        #expect(try decode(#"{"question":{"text":"q"},"answers":[]}"#) == nil)
    }

    /// An answer with neither words nor a glyph cannot be voted for by anybody
    /// who can see it.
    @Test("A blank answer is dropped")
    func blankAnswer() throws {
        let poll = try #require(try decode("""
        {"question":{"text":"q"},
         "answers":[{"answer_id":1,"poll_media":{"text":""}},
                    {"answer_id":2,"poll_media":{"text":"B"}}]}
        """))
        #expect(poll.answers.count == 1)
        #expect(poll.answers[0].id == 2)
    }
}
