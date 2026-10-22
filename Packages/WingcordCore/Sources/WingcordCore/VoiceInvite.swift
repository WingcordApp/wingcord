import Foundation

// MARK: - An invite to a voice channel
//
// Discord's voice invite embed (`dF` in web build 641803's message chunk): for
// an invite to a server's voice channel the reader can see, the card says who
// is in there — "Invited you to join them and 2 others in voice" — with their
// faces, and its button joins the call. Strings verbatim from the English
// catalogue; the card is the reader's alone, so it can say who is inside, and
// says so: "Only server members can see who's in voice".

public enum VoiceInvite {

    /// The card's two lines (`DVDvCD`, `TY77rq`, `wM2WTM`, `2RWMFV`,
    /// `IWXzHV`, `Da7tZx`, `3VbQvv`).
    ///
    /// - Parameters:
    ///   - sentByReader: the reader posted the invite.
    ///   - authorIsInChannel: whoever posted it is in the channel now.
    ///   - peopleInChannel: everybody in it, the author included.
    public static func lines(
        sentByReader: Bool,
        authorIsInChannel: Bool,
        peopleInChannel: Int
    ) -> (label: String, sublabel: String?) {
        guard peopleInChannel > 0 else {
            return (sentByReader ? "Sent an invite to join voice" : "Invited you to join voice",
                    "No one is currently in voice")
        }
        let others = peopleInChannel - (authorIsInChannel ? 1 : 0)
        let label: String = switch (sentByReader, authorIsInChannel) {
        case (true, true): "Sent an invite to join you\(andOthers(others)) in voice"
        case (true, false): "Sent an invite to join " + (others == 0 ? "voice" : "\(count(others)) in voice")
        case (false, true): "Invited you to join them\(andOthers(others)) in voice"
        case (false, false): "Invited you to join\(others == 0 ? "" : " \(count(others))") in voice"
        }
        return (label, nil)
    }

    /// " and 2 others", or nothing.
    private static func andOthers(_ others: Int) -> String {
        others == 0 ? "" : " and \(count(others))"
    }

    private static func count(_ others: Int) -> String {
        "\(others.formatted()) \(others == 1 ? "other" : "others")"
    }

    /// Discord's face pile (`dB`): every face up to four, or three and a
    /// "+N" past four — N counting the fourth too.
    public static func pile(count: Int) -> (faces: Int, overflow: Int?) {
        count > 4 ? (3, count - 3) : (count, nil)
    }

    /// The overflow bubble's words: past 99 Discord writes ">99".
    public static func overflowLabel(_ overflow: Int) -> String {
        overflow > 99 ? ">99" : "+\(overflow)"
    }

    /// Each face's side, in order — the first is the largest: one face 80;
    /// two 60 and 40; more 60, 48, then 40 (`dB`'s avatar sizes).
    public static func faceSides(faces: Int, hasOverflow: Bool) -> [Double] {
        let drawn = min(hasOverflow ? faces + 1 : faces, 4)
        return (0..<faces).map { index in
            switch (drawn, index) {
            case (1, _): 80
            case (2, 0): 60
            case (2, _): 40
            case (_, 0): 60
            case (_, 1): 48
            default: 40
            }
        }
    }

    /// The people to draw, the author first — Discord then orders the rest by
    /// how likely the reader is to call them, which this client does not know,
    /// so by when they joined.
    public static func ordered<ID: Hashable>(_ people: [ID], author: ID) -> [ID] {
        people.contains(author) ? [author] + people.filter { $0 != author } : people
    }
}
