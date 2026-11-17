import SwiftUI

// MARK: - A call that is already happening, without you
//
// **The same place the call takes, before you are in it.** A conversation whose
// call you have left — or never joined — used to show nothing at all, and the
// only way back was a toolbar button that said "Start a Call" and rang the
// person still sitting in it. So the call stays where it was, and joining is
// stepping back into a thing that is visibly still going.
//
// **One short row** (Alex, 2026-11-17): who is in there on the left, the ways
// in on the right. It was a strip of live tiles with a button under it, and a
// call with one person in it came out as one small tile dwarfed by its Join
// button; faces at the button's own height keep the two in proportion
// whatever the count. Joining grows the row into the band, which is the motion
// that says what happened.
//
// **No video.** Nothing is subscribed to anybody's camera until the reader
// joins — see `AppModel.callLobby`. A lobby that decoded a stream would spend
// a call's worth of CPU on a panel nobody has stepped into.
struct VoiceCallLobby: View {
    var participants: [VoiceParticipant]
    /// An activity running in the call, joinable from here (joining it joins
    /// the call first).
    var activity: CallActivityPresentation? = nil
    var joinActivity: (CallActivityPresentation) -> Void = { _ in }
    var join: () -> Void

    /// Shorter than the call itself, and that is the point: this is the call
    /// waiting, not the call.
    static let height: CGFloat = 64

    var body: some View {
        HStack(spacing: Spacing.snug) {
            CallLobbyFaces(participants: participants)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            // The names give way before the buttons do.
            .layoutPriority(-1)
            Spacer(minLength: Spacing.base)
            if let activity {
                CallLobbyActivityButton(activity: activity) { joinActivity(activity) }
            }
            CallLobbyJoinButton(title: title, hint: hint, action: join)
        }
        .padding(.horizontal, Spacing.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Frosted, as the band is (Alex, 2026-11-17: "i wanted blur").
        .background { CallBandGround() }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        participants.count == 1 ? "Join \(participants[0].displayName)" : "Join the Call"
    }

    /// Who is in there, in the fewest words that name them.
    private var headline: String {
        let names = participants.map(\.displayName)
        return switch names.count {
        case 0: "Nobody"
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// What they're doing: talking, or waiting.
    private var subtitle: String {
        if let speaker = participants.first(where: \.isSpeaking) {
            return participants.count == 1 ? "Talking in the call" : "\(speaker.displayName) is talking"
        }
        return participants.count == 1 ? "In the call" : "\(participants.count) people in the call"
    }

    /// What VoiceOver is told, which is the thing a sighted reader gets from
    /// the faces: who is in there.
    private var hint: String {
        let names = participants.map(\.displayName)
        return switch names.count {
        case 0: "Nobody is in this call."
        case 1: "\(names[0]) is in this call."
        case 2: "\(names[0]) and \(names[1]) are in this call."
        default: "\(names[0]), \(names[1]) and \(names.count - 2) others are in this call."
        }
    }
}
