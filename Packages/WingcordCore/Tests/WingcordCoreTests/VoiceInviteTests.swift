import Foundation
import Testing
@testable import WingcordCore

/// A voice invite's card: what it says about who is inside.
struct VoiceInviteTests {

    @Test("Nobody in voice: who sent it, and that nobody is there")
    func empty() {
        let mine = VoiceInvite.lines(sentByReader: true, authorIsInChannel: false, peopleInChannel: 0)
        #expect(mine.label == "Sent an invite to join voice")
        #expect(mine.sublabel == "No one is currently in voice")
        let theirs = VoiceInvite.lines(sentByReader: false, authorIsInChannel: false, peopleInChannel: 0)
        #expect(theirs.label == "Invited you to join voice")
    }

    @Test("Discord's four sentences, with the others counted and the author not")
    func sentences() {
        #expect(VoiceInvite.lines(sentByReader: false, authorIsInChannel: true, peopleInChannel: 1).label
                == "Invited you to join them in voice")
        #expect(VoiceInvite.lines(sentByReader: false, authorIsInChannel: true, peopleInChannel: 3).label
                == "Invited you to join them and 2 others in voice")
        #expect(VoiceInvite.lines(sentByReader: false, authorIsInChannel: false, peopleInChannel: 1).label
                == "Invited you to join 1 other in voice")
        #expect(VoiceInvite.lines(sentByReader: true, authorIsInChannel: true, peopleInChannel: 2).label
                == "Sent an invite to join you and 1 other in voice")
        #expect(VoiceInvite.lines(sentByReader: true, authorIsInChannel: false, peopleInChannel: 4).label
                == "Sent an invite to join 4 others in voice")
        #expect(VoiceInvite.lines(sentByReader: true, authorIsInChannel: true, peopleInChannel: 3).sublabel == nil)
    }

    @Test("Four faces fit; past four, three and the rest as +N")
    func pile() {
        #expect(VoiceInvite.pile(count: 4) == (4, nil))
        #expect(VoiceInvite.pile(count: 5) == (3, 2))
        #expect(VoiceInvite.pile(count: 150) == (3, 147))
        #expect(VoiceInvite.overflowLabel(2) == "+2")
        #expect(VoiceInvite.overflowLabel(147) == ">99")
    }

    @Test("Faces shrink after the first, as Discord sizes them")
    func sides() {
        #expect(VoiceInvite.faceSides(faces: 1, hasOverflow: false) == [80])
        #expect(VoiceInvite.faceSides(faces: 2, hasOverflow: false) == [60, 40])
        #expect(VoiceInvite.faceSides(faces: 3, hasOverflow: true) == [60, 48, 40])
        #expect(VoiceInvite.faceSides(faces: 4, hasOverflow: false) == [60, 48, 40, 40])
    }

    @Test("The author leads the pile")
    func order() {
        #expect(VoiceInvite.ordered([1, 2, 3], author: 3) == [3, 1, 2])
        #expect(VoiceInvite.ordered([1, 2], author: 9) == [1, 2])
    }
}
